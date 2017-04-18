---
title:  "SDMA Hacking Part 5: Custom SPI Script"
tags: code sdma
---
# {{ page.title }}

Ok! If you've made it this far, you should have a pretty good idea of the inner workings of the SDMA and the ROM and RAM scripts which it uses.  Now, we have all the info we need to complete our task.  We're going to rewrite the `mcu_2_ecspi` script with two important changes:

* We'll remove the part where it reads from main memory.  Instead, we'll generate dummy values to write to the SPI TX FIFO. without creating extra bus traffic.
* We'll write to the ECSPI module via the shared bus, rather than via the AXI bus.

Also, we'll make the effort to preserve the bugfix included in the `mcu_2_ecspi` script.

## Jump Instructions

The SDMA doesn't have a relative jump instruction.  The only jump instructions it has all go to absolute addresses.  This isn't great for us, as we don't know where in memory our script will be loaded at compile time.  However, the SDMA does have relative branch instructions (BF, BT, etc).  We'll use these to *fake* a relative jump instruction.

So, when we're looking at a line from `mcu_2_ecspi` like this:

```assembly
    jmp        6185                     # 6180  # goto byte combiner 
```

We can translate this line into our new script as:

```assembly
    cmpeq      r1, r1  # always true
    bt         byte_combiner
```

Eli's assembler will find the relative offset of the `byte_combiner` label, and fix the bt instruction to move PC to the correct spot.  Incidentally, this pattern will destroy the state of the T flag, which you may find is important to the code, and wants to be preserved across the jump.  In this case, maybe a better pattern is:

```assembly
    bt         byte_combiner  #  one way...
    bf         byte_combiner  #  ...or the other
```

This gets you a relative jump-like pattern without affecting you processor flags.  It does change the length of your program, though, so use caution!

## The Code!

Ok, so let's start out our code by assuming that the registers and buffer descriptors are set up exactly as for mcu_2_shp.

We should begin by making use of that nifty shared peripheral address rewriter, and then call the standard setup subroutine:

```assembly
zeros_2_ecspi:
    jsr        473        # rewrite shp_addr from AP address into SPBA address
    jsr        485        # load BD, r5 = buf remaining
main_loop:
    ld         r7, (r3, 0x1b)   # r7 = "burst length"
    ld         r2, (r3, 0x1e)   # r2 = "BD buffer addr"
```

Then, we need to reproduce the bugfix contained in the `mcu_2_ecspi` script.  However, instead of using the Peripheral DMA module to read the TESTREG, let's used the shared peripheral bus, like so:

```assembly
xfer_loop:
    ld         r2, (r3, 0x1f)     # r2 = scratch1f (shp_addr)
    ld	       r2, (r2, 0x1c)	    r2 = *(ECSPIx_TXDATA + 0x1c == ECSPIx_TESTREG)
    revblo     r2                 # get RXCNT in low order bits
    andi       r2, 0xff           # mask off other stuff
    ldi        r0, 0x30           # r0 = 48
    cmplt      r2, r0             # if RXCNT >= 48
    bf         yield_for_now      #    then jump to yield and wait
```

Let's hope that does the trick!  Now we are free to proceed with the burst handling code.

```assembly
    mov        r0, r7     # r0 = r7 (burst length)
    bclri      r0, 0x1f   # clear high bit of burst length (??)
    cmplt      r0, r5     # if burst_length < buf_remaining:
    bt         1	  #   skip next line
    mov        r0, r5          # else r0 = burst_length
    sub        r5, r0          # buf_remaining -= burst_length
    st         r5, (r3, 0x1d)  # scratch1d = r5 (buf_remaining)

    btsti      r4, 0x18        # ** Truth table for mode bits
    bt         3               # | b24  b25
    btsti      r4, 0x19        # |  n
    bt         mode_16b        # |  n    y,  goto mode_16b
    bf         mode_32b        # |  n    n,  goto mode_32b
    btsti      r4, 0x19        # |  y
    bf         mode_8b         # |  y    n,  goto mode_8b
                               # |  y    y,  24b mode.  fall through...
    ld         r6, (r6, 0x1d)  # r6 = scratch1d (buf_remaining)
```

My annotation of the original code had a note here saying how 24-bit mode is tricky.  But if we don't need to read from DRAM, we don't need to concern ourselves with alignment!  So this code becomes simpler.

```assembly
    ldi	       r2, 0x0	       	 # r2 = 0 (dummy data)
    ld	       r5, (r3, 0x1f)	 # r5 = shp_addr
loop_24b:
    st	       r2, (r5, 0x0)	 # write zero to shp
    bdf        do_fault	        
    subi       r0, 0x3           # burst remaining -= 3 bytes
    cmpeqi     r0, 0x0           # test if done
    bf         loop_24b          #   if not done, do loop again
    bt         cleanup           # otherwise, clean up.
```

The loops for the other 3 data widths become *very* simple indeed!


```assembly
mode_32b:
    lsr1       r0
mode_16b:
    lsr1       r0
mode_8b:
    ldi	       r2, 0x0		# r2 = 0 (dummy data)
    ld	       r5, (r3, 0x1f)	# r5 = shp_addr

    loop       1, 0             
    st	       r2, (r5, 0x0)	# write zero to shp    
    bf	       do_fault
    bt         cleanup          
```

Then we have the cleanup routine, which reproduces another part of the bugfix from mcu_2_ecspi:

```assembly
cleanup:
    btsti      r7, 0x1f          # test high bit of burst length
    bt         yield_for_now     # if true (when??) goto 6222
    ld         r2, (r3, 0x1f)    # r2 = shp_addr
    ld	       r5, (r2, 0x4)     # r5 = *(shp_addr+4) (aka ECSPIx_CONREG)
    ori	       r5, 0x4	         # r5 |= XCH
    st	       r5, (r2, 0x4)     # write CONREG
```

And then finally the `yield_for_now` handler referenced above, and the `do_fault` and `load_next_bd` handlers as well.  You'll notice a few instances of the relative jump-like pattern in here.

```assembly
yield_for_now:
    done       0               # yield, no interrupt
    ld         r5, (r3, 0x1d)  # r5 = buf_remaining
    cmpeqi     r5, 0x0         # if buf_remaining == 0
    bt         load_next_bd    #   goto load next bd
    jsr        508             # else call 508
    ld         r7, (r3, 0x1b)  # restore r7 from proc 508
    cmpeq      r0, r0
    bt         xfer_loop       # goto xfer_loop

do_fault: 
    clrf       0              
    jsr        533            

load_next_bd:
    jsr        524             # buf_remaining == 0, load next BD
    cmpeq      r0, r0
    bt         main_loop       # goto main loop.
```

And that does it!  This should result in much better utilization of the SDMA core during RX-only SPI transfers.  In my testing, I can verify that this increases the maximum throughput of incoming SPI transactions to beyond the capabilities of my SPI slave devices, which is good enough for my needs.

I hope you've found this series useful!  Thanks much for reading.

- Jonah
