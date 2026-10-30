#!/usr/bin/perl
# Remove the macOS recovery partition from a Tart VM's raw disk image and re-write the GPT so that
# it fits the (possibly enlarged) image file. Offline operation: the VM must be stopped.
#
# This does what packer-plugin-tart's `recovery_partition = "delete"` does: macOS refuses to delete
# the recovery partition from the host with diskutil or gpt(8), so the partition table is edited directly.
# Afterwards the free space sits right behind the system container, where the Tart guest agent
# (--run-daemon) can grow it at the next boot.
use strict;
use warnings;
use Compress::Zlib qw(crc32);

my $img = shift or die "usage: $0 <disk.img>\n";
open(my $fh, '+<:raw', $img) or die "cannot open $img: $!\n";
my $size = -s $img;
my $last_lba = int($size / 512) - 1;

sub rd { my ($off, $len) = @_; seek($fh, $off, 0) or die "seek: $!"; read($fh, my $buf, $len) == $len or die "short read at $off\n"; $buf }
sub wr { my ($off, $buf) = @_; seek($fh, $off, 0) or die "seek: $!"; print $fh $buf or die "write: $!"; }

my @f = unpack('a8 V V V V Q< Q< Q< Q< a16 Q< V V V', rd(512, 92));
my ($sig, $rev, $hsz, undef, undef, undef, $old_alt, $first, undef, $guid, $pe_lba, $npe, $pesz) = @f;
die "$img has no GPT\n" unless $sig eq 'EFI PART' && $hsz == 92 && $pesz == 128;

my $esectors = $npe * $pesz / 512;
my $ents = rd($pe_lba * 512, $npe * $pesz);

my $recovery_type = pack('V v v C8', 0x52637672, 0x7900, 0x11AA, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC);
my ($rec_idx, $last_used) = (-1, -1);
for my $i (0 .. $npe - 1) {
  my $e = substr($ents, $i * $pesz, $pesz);
  next if substr($e, 0, 16) eq "\0" x 16;
  $last_used = $i;
  my $name = join('', map { chr } unpack('v*', substr($e, 56, 72))); $name =~ s/\0.*//s;
  $rec_idx = $i if substr($e, 0, 16) eq $recovery_type || $name eq 'RecoveryOSContainer';
}
if ($rec_idx >= 0) {
  die "the recovery partition is not the last partition (entry " . ($rec_idx + 1) . " of " . ($last_used + 1) . "), refusing to proceed\n" if $rec_idx != $last_used;
  substr($ents, $rec_idx * $pesz, $pesz) = "\0" x $pesz;
  print "removed recovery partition (GPT entry " . ($rec_idx + 1) . ")\n";
} else {
  print "no recovery partition found, only re-writing the GPT for the current image size\n";
}

my $ent_crc = crc32($ents);
my $last_usable = $last_lba - 1 - $esectors;

sub header {
  my ($my_lba, $alt_lba, $pe) = @_;
  my $h = pack('a8 V V V V Q< Q< Q< Q< a16 Q< V V V', 'EFI PART', $rev, 92, 0, 0, $my_lba, $alt_lba, $first, $last_usable, $guid, $pe, $npe, $pesz, $ent_crc);
  substr($h, 16, 4) = pack('V', crc32($h));
  $h . ("\0" x (512 - 92));
}

# wipe the previous backup GPT (it sat at the old end of the disk) unless that is still the end
if ($old_alt != $last_lba) {
  wr(($old_alt - $esectors) * 512, "\0" x (($esectors + 1) * 512));
}
wr($pe_lba * 512, $ents);                                  # primary entries
wr(512, header(1, $last_lba, $pe_lba));                    # primary header
wr(($last_lba - $esectors) * 512, $ents);                  # backup entries
wr($last_lba * 512, header($last_lba, 1, $last_lba - $esectors));   # backup header
close($fh) or die "close: $!";
print "GPT re-written for $size bytes ($last_lba is the last LBA)\n";
