---
title:  "SDMA Hacking Part 2: Creating Custom Scripts"
tags: code sdma
---
# {{ page.title }}

Ok, by the end of this entry, you'll know everything you need in order to run your own SDMA scripts from Linux!  Let's dig right in.

## A Simple Script

The next step is to create a custom script, and modify the SDMA driver to allow us to run it.  For this example, we'll use the sample script from Eli Billauer's blog:

```
start:
    ldi r0, 4	    # r0 = 4 
    loop exit, 0    # loop 4 times, then goto 'exit'
    st r4, (r5, 0)  #   *r5 = r4
    addi r5, 1	    #   r5 += 1
    addi r4, 0x10   #   r4 += 0x10
exit:
    done 3          # interrupt ARM core, pause script
    addi r4, 0x40   # r4 += 0x40
    ldi r3, 0       # r3 = 0
    cmpeqi r3, 0    # if r3 == 0 (Always true)
    bt start	    #    goto 'start'
```

I've annotated the above in C-ish code, for the curious.  All you really need to know is that the script writes to some SDMA-local memory, and signals the ARM core.  Nothing too useful, but we can have Linux receive the interrupt, and be fairly sure that the script is running.  A good beginning.

## Assembler

I should pause here to make a note about the toolchain for building SDMA binaries.  I hear that there is a real one somewhere, and the i.MX25 Reference Manual even makes reference to an API which custom scripts can call.  However, none of that is available any more, or is at a minimum locked away behind NDAs.

Luckily, the instruction set is quite simple, and Eli Billauer wrote a perfectly capable assembler in Perl, which I copied and altered so that it would produce raw script binaries.  My version is available [here].  Typical usage is something like:
```
./sdma_asm.pl first-script.asm > /tmp/out.asm
```

This will produce output to stderr for you to look at, and also write the assembled binary to /tmp/out.asm.

## Running Custom Scripts with the Linux SDMA Driver

The Linux SDMA driver doesn't have native support for running custom scripts.  But it's not too hard to add, so let's do it!  I made the following changes against Linux 4.1.15 from the [linux-fslc](https://github.com/Freescale/linux-fslc) repository's 4.1-2.0.x-imx branch.  But they could be easily adapted to other situations.

- Reserve a channel
- RAM script end marker
- User script sysfs entry
- Registers sysfs entries
- Trigger sysfs entry

## Context Snapshot for Debugging

The SDMA engine only runs one channel at a time.  Each channel's script must explicitly yield its time for other scripts to have a chance to run.  When a script yields and the SDMA switches to another script, it preserves the registers of the yielding script to SDMA internal RAM in what's called a "channel context".  The layout of this context is specified in the reference manual.  In the iMX7D manual, it's in Table 7-13, "Layout of a Channel Context in Memory for SDMA", but it appears in each i.MX version's manual in more or less the same form.

We can take advantage of this context saving by actually downloading the context from the SDMA to the CPU for examination.  This gives us a good idea of what the SDMA was doing when it switched contexts, including the PC, error flags, general and scratch registers, etc.

- Updated version of Eli's context dumper, including scratch registers.

