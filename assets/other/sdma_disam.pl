#!/usr/bin/perl

# (c) Exslestonec, 2015. exslestonec@mail.ru

# The code contained herein is licensed under the GNU General Public
# License. You may obtain a copy of the GNU General Public License
# Version 2 or later at the following locations:
#
# http://www.opensource.org/licenses/gpl-license.html
# http://www.gnu.org/copyleft/gpl.html

use warnings;
use strict;
use lib '.';


my $use_hexcode=0;
my $use_stdin=0;
my $filename=0;
my $disassembly;
my $binary;
my $commentlines=0;
my $commentoffset=0;


#                          cmd               bin        binmask      dispatcher
my @instructions=(    "    done       " ,    0x0000,    0x0700,      \&dj8x3 ,
		      "    yield      " ,    0x0000,    0x0700,      \&dnoargs ,
		      "    yieldge    " ,    0x0100,    0x0700,      \&dnoargs ,
		      "    notify     " ,    0x0001,    0x0700,      \&dj8x3 ,
		      "    softbkpt   " ,    0x0005,    0x0000,      \&dnoargs ,
		      "    ret        " ,    0x0006,    0x0000,      \&dnoargs ,
		      "    clrf       " ,    0x0007,    0x0400,      \&df8x2 ,
		      "    illegal    " ,    0x0707,    0x0000,      \&dnoargs ,
		      "    jmpr       " ,    0x0008,    0x0700,      \&dr8x3 ,
		      "    jsrr       " ,    0x0009,    0x0700,      \&dr8x3 ,
		      "    ldrpc      " ,    0x000a,    0x0700,      \&dr8x3 ,
		      "    revb       " ,    0x0010,    0x0700,      \&dr8x3 ,
		      "    revblo     " ,    0x0011,    0x0700,      \&dr8x3 ,
		      "    rorb       " ,    0x0012,    0x0700,      \&dr8x3 ,
		      "    ror1       " ,    0x0014,    0x0700,      \&dr8x3 ,
		      "    lsr1       " ,    0x0015,    0x0700,      \&dr8x3 ,
		      "    asr1       " ,    0x0016,    0x0700,      \&dr8x3 ,
		      "    lsl1       " ,    0x0017,    0x0700,      \&dr8x3 ,
		      "    bclri      " ,    0x0020,    0x071f,      \&dr8x3_n0x5 ,
		      "    bseti      " ,    0x0040,    0x071f,      \&dr8x3_n0x5 ,
		      "    btsti      " ,    0x0060,    0x071f,      \&dr8x3_n0x5 ,
		      "    mov        " ,    0x0088,    0x0707,      \&dr8x3_s0x3 ,
		      "    xor        " ,    0x0090,    0x0707,      \&dr8x3_s0x3 ,
		      "    add        " ,    0x0098,    0x0707,      \&dr8x3_s0x3 ,
		      "    sub        " ,    0x00a0,    0x0707,      \&dr8x3_s0x3 ,
		      "    or         " ,    0x00a8,    0x0707,      \&dr8x3_s0x3 ,
		      "    andn       " ,    0x00b0,    0x0707,      \&dr8x3_s0x3 ,
		      "    and        " ,    0x00b8,    0x0707,      \&dr8x3_s0x3 ,
		      "    tst        " ,    0x00c0,    0x0707,      \&dr8x3_s0x3 ,
		      "    cmpeq      " ,    0x00c8,    0x0707,      \&dr8x3_s0x3 ,
		      "    cmplt      " ,    0x00d0,    0x0707,      \&dr8x3_s0x3 ,
		      "    cmphs      " ,    0x00d8,    0x0707,      \&dr8x3_s0x3 ,
		      "    cpshreg    " ,    0x06e2,    0x0000,      \&dnoargs ,
		      "    ldi        " ,    0x0800,    0x07ff,      \&dr8x3_i0x8 ,
		      "    xori       " ,    0x1000,    0x07ff,      \&dr8x3_i0x8 ,
		      "    addi       " ,    0x1800,    0x07ff,      \&dr8x3_i0x8 ,
		      "    subi       " ,    0x2000,    0x07ff,      \&dr8x3_i0x8 ,
		      "    ori        " ,    0x2800,    0x07ff,      \&dr8x3_i0x8 ,
		      "    andni      " ,    0x3000,    0x07ff,      \&dr8x3_i0x8 ,
		      "    andi       " ,    0x3800,    0x07ff,      \&dr8x3_i0x8 ,
		      "    tsti       " ,    0x4000,    0x07ff,      \&dr8x3_i0x8 ,
		      "    cmpeqi     " ,    0x4800,    0x07ff,      \&dr8x3_i0x8 ,
		      "    ld         " ,    0x5000,    0x07ff,      \&dr8x3_d3x5_b0x3 ,
		      "    st         " ,    0x5800,    0x07ff,      \&dr8x3_d3x5_b0x3 ,
		      "    ldf        " ,    0x6000,    0x07ff,      \&dr8x3_u0x8 ,
		      "    stf        " ,    0x6800,    0x07ff,      \&dr8x3_u0x8 ,
		      "    loop       " ,    0x7800,    0x03ff,      \&df8x2_n0x8 ,
		      "    bf         " ,    0x7c00,    0x00ff,      \&dp0x8 ,
		      "    bt         " ,    0x7d00,    0x00ff,      \&dp0x8 ,
		      "    bsf        " ,    0x7e00,    0x00ff,      \&dp0x8 ,
		      "    bdf        " ,    0x7f00,    0x00ff,      \&dp0x8 ,
		      "    jmp        " ,    0x8000,    0x3fff,      \&da0x14 ,
		      "    jsr        " ,    0xc000,    0x3fff,      \&da0x14 ,
		    );


while(@ARGV)
{
  my $param = shift @ARGV;
  if($param eq "-f") { $filename = shift @ARGV; }
  if($param eq "-x") { $use_hexcode = 1; }
  if($param eq "-i") { $use_stdin = 1; }
  if($param eq "-h") { print_help(); }
  if($param eq "--comment") { $commentlines=1; $commentoffset= shift @ARGV;}
}

open(my $file,$filename)|| die "can't open file '$filename': $!";
if( $use_hexcode )
{
   readhex($file);
}
else
{
   read($file, $binary, 4000000)||die "can't read file input file: $.";
   #$binary = <$file>;
}

disassemble();
close($file);




sub print_help
{
   print "-f <FILENAME>\tFile to read as input\n-x\t\tThe code is formatted to c++ hex format\n-i\t\tuse stdin ad input\n--comment OFFSET\tcommend the line number\n-h\t\tprint this help\n";
   exit(0);
}


sub readhex
{
   my($file) = @_;
   my $char;
   my $cmd;  

   while(read($file,$char,1) > 0)
   {
      if($char ne "," && $char ne ";")
      {
         if($char !~ /[ \n\t\r]/)
         {
            $cmd=$cmd.$char
         }
      }
      else
      {
         $cmd =~ s/0x//g;
		 $binary .= pack("n", hex $cmd);
         $cmd="";
      }
   }
}

sub disassemble
{
   my $cmdbin;
   my $found = 0;
   my $j;
   my $i;
   my $linefeed_pos = 0;

   for($i=0; $i < length($binary);$i+=2)
   {
      $cmdbin = unpack("n",substr($binary,$i, 2));
      $found = 0;

      for($j=0; $j < $#instructions; $j+=4)
      {
         # mask registers, immidiates, etc in the command
         my $maskedcmd = $cmdbin & ~$instructions[$j+2];
         # check if we have the right command
         if($maskedcmd == $instructions[$j+1])
         {
            $found = 1;
            last;
         }
      }
      if($found)
      {
         my $cmd = $instructions[$j];
	 my $pc = ($i/2)+$commentoffset;
         $instructions[$j+3]($cmd, $cmdbin, $pc);
	 if($commentlines == 1)
	 {
	     my $len = 40 - (length($disassembly) - $linefeed_pos);
	     if ($len > 0) {
	         $disassembly .= ' ' x $len;
	     }
	     $disassembly.="%".(($i/2)+$commentoffset)."\n";
	 }
	 else
	 {
		$disassembly.="\n";
	 }
	 $linefeed_pos = length($disassembly);
      }
      else
      {
         printf STDERR ("WARNING: unknown 0x%x command line: %d\n", $cmdbin,($i/2));
      }
   }
   print $disassembly;    
}

sub imm
{
   my($imm) = @_;
   return sprintf("0x%x", $imm);    
}

# done
sub dj8x3
{
   my($cmd, $cmdbin) = @_;

   my $jjj = (($cmdbin & (7 << 8)) >> 8);
   $disassembly .= $cmd.$jjj;
}

# illegal
sub dnoargs
{
   my($cmd, $cmdbin) = @_;

   $disassembly .= $cmd;
}

# jmpr
sub dr8x3
{
   my($cmd, $cmdbin) = @_;

   my $rrr = (($cmdbin & (7 << 8)) >> 8);
   $disassembly .= $cmd."r".$rrr;
}

# clrf
sub df8x2
{
   my($cmd, $cmdbin) = @_;

   my $ff = (($cmdbin & (3 << 8)) >> 8);
   $disassembly .= $cmd.$ff;
}

# bclri
sub dr8x3_n0x5
{
   my($cmd, $cmdbin) = @_;

   my $rrr = (($cmdbin & (7 << 8)) >> 8);
   my $i = imm($cmdbin & 0x1f);
   $disassembly .= $cmd."r".$rrr.", $i";
}

# ldi
sub dr8x3_i0x8
{
   my($cmd, $cmdbin) = @_;

   my $rrr = (($cmdbin & (7 << 8)) >> 8);
   my $i = imm($cmdbin & 0xff);
   $disassembly .= $cmd."r".$rrr.", $i";
}

# ld
sub dr8x3_d3x5_b0x3
{
   my($cmd, $cmdbin) = @_;

   my $rrr = (($cmdbin & (7 << 8)) >> 8);
   my $bbb = ($cmdbin & 7);
   my $d = imm(($cmdbin & (0x1f << 3)) >> 3);
   $disassembly .= $cmd."r$rrr".", (r$bbb, $d)";
}

# ldf
sub dr8x3_u0x8
{
   my($cmd, $cmdbin) = @_;

   my $rrr = (($cmdbin & (7 << 8)) >> 8);
   my $i = ($cmdbin & 0xff);
   $disassembly .= $cmd."r".$rrr.", $i";
}

# mov
sub dr8x3_s0x3
{
   my($cmd, $cmdbin) = @_;

   my $rrr = (($cmdbin & (7 << 8)) >> 8);
   my $sss = ($cmdbin & 7);
   $disassembly .= $cmd."r$rrr, r".$sss;
}

# loop
sub df8x2_n0x8
{
   my($cmd, $cmdbin) = @_;

   my $ff = (($cmdbin & (3 << 8)) >> 8);
   my $n = ($cmdbin & 0xff);
   $disassembly .= $cmd.$n.", ".$ff;
}

# bf
sub dp0x8
{
   my($cmd, $cmdbin, $pc) = @_;

   my $p = ($cmdbin & 0xff);
   if ($p > 127)
   {
      $p = $p - 256;
   }
   my $target = $pc + 1 + $p;
   $disassembly .= $cmd.$p." (%$target)";
}

# jmp
sub da0x14
{
   my($cmd, $cmdbin) = @_;

   my $p = ($cmdbin & 0x3fff);
   $disassembly .= $cmd.$p;
}
