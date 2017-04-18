---
title:  "SDMA Hacking Part 4: Standard ROM Scripts"
tags: code sdma
---
# {{ page.title }}

Way back in Part I of this series, I spoke of my main goal: to write a script which optimized the process of reading data from the i.MX's SPI module and copying it to main memory.

## AXI, SPBA, and MCU, oh my!

First, let me talk about the flow of data which I think is optimal.  From the block diagram of the i.MX7, one can see tha the SDMA has direct access to the shared peripheral bus via the Shared Peripheral Bus Arbiter (SPBA).  This direct access means that the SDMA can read and write to the peripherals on this bus without signaling via the main bus (a.k.a. AXI bus or AHB bus).  This is preferrable, as these peripherals can use enough data that the SDMA seems to be unable to keep up at times, if it has to bounce all data out to the AXI bus and back.

Here's the block diagram of the i.MX7, with the SDMA, SPBA and SPI modules highlighted.  We want to have the communication between the SPI module and the SDMA happen over the SPBA (in green below), and *not* via the AXI bus (orange, below).  Only data destined for DRAM should go out over the AXI bus.

![i.MX block diagram with SPBA, SDMA, and AXI highlighted](/assets/img/NXP-i.MX7-Block-Diagram.png)

## shp_2_mcu, mcu_2_shp, and mcu_2_ecspi

So, how well do the standard scripts do at achieving this goal?  The standard devtree for the i.MX7 includes the following:

```
  ecspi1: ecspi@30820000 {
	// [snip]
  	dmas = <&sdma 0 7 1>, <&sdma 1 7 2>;
  	dma-names = "rx", "tx";
  };
```

The SDMA handles take 3 parameters.  The first is the SDMA request number which is activated by that particular peripheral.  You can look these up in the "SDMA event mapping" section of the reference manual.  For the i.MX7, this looks like:

| SDMA |  Module | Description |
| ---- | ------- | ----------- |
| 0 | ECSPI1 | eCSPI1 Rx request |
| 1 | ECSPI1 | eCSPI1 Tx request |
| 2 | ECSPI2 | eCSPI2 RX request |
| etc...  |

So, the first SDMA channel above will be triggered by a RX request from the SPI 1 module, and the second by a TX request from the same module.

The second parameter to the sdma handle above is the peripheral type.  These are found in dma-imx.h, and in this case, 7 is equivalent to `IMX_DMATYPE_CSPI`.  Here we find our first optimization over the standard distribution!  The ECSPI1 module is available on the shared peripheral bus, and there's a specific script for communicating with peripheral modules like the eCSPI via the SPBA, rather than over the main bus.  

Checking the other types available in `dma-imx.h`, one can see the `IMX_DMATYPE_CSPI_SP` type, where "SP" stands for "shared peripiheral".  Looking in `sdma_get_pc()`, we see that the `IMX_DMATYPE_CSPI_SP` causes the script `mcu_2_shp` to be loaded on that channel.  Just this one change should result in a 50% reduction in AXI bus traffic, as the data going from the SDMA to the ECSPI module will not have to pass through the main bus!  Sweet.

But wait!  If you try this out, you'll find something mysterious!  It doesn't seem to work.  No traffic flows.  What's up?

Digging a bit, you might notice that the original, working peripheral type `IMX_DMATYPE_CSPI` used a script called `mcu_2_ecspi`, rather than the standard, generic `mcu_2_app`.  Huh!  A specific script for SPI peripherals, where all other peripherals use a generic script?  Seems suspiciously like a bugfix implemented in software.  Another piece of evidence for that theory is that this special script is part of the SDMA's RAM scripts package, rather than using the script from the ROM.

It seems that if we're going to accomplish our goal, we're going to need to know what this new script is doing, and reproduce its bugfix in a shared peripheral-specific script.

## Downloading the ROM and RAM scripts

Making use of the techniques from Eli's series, we'll add the ability for imx-sdma.c to dump the ROM and RAM sections of the SDMA internal memory.

```c
static ssize_t dump_sdma_page(struct sdma_engine *sdma, int page_num, char *output)
{
	const int PAGE_BYTES = 4096;
	struct sdma_buffer_descriptor *bd0 = sdma->bd0;
	unsigned long flags;
	void *buf_virt;
	dma_addr_t buf_phys;
	int ret, i;

	buf_virt = gen_pool_dma_alloc(sdma->iram_pool, PAGE_BYTES, &buf_phys);
	if (!buf_virt) {
		dev_warn(sdma->dev, "unable to allocate IRAM buffer for SDMA ROM transfer");
		return -EINVAL;
	}
	memset(buf_virt, 0, PAGE_BYTES);

	clk_enable(sdma->clk_ipg);
	clk_enable(sdma->clk_ahb);

	spin_lock_irqsave(&sdma->channel_0_lock, flags);
	bd0->mode.command = C0_GETDM;
	bd0->mode.status = BD_DONE | BD_INTR | BD_WRAP | BD_EXTD;
	bd0->mode.count = PAGE_BYTES / 4;
	bd0->buffer_addr = buf_phys;
	bd0->ext_buffer_addr = (PAGE_BYTES/4) * page_num;
	ret = sdma_run_channel0(sdma);
	spin_unlock_irqrestore(&sdma->channel_0_lock, flags);

	memcpy(output, buf_virt, PAGE_BYTES);
	for (i = 0; i < PAGE_BYTES; i+=4) {
		u32* ptr = (u32*)&output[i];
		cpu_to_be32s(ptr);
	}

	gen_pool_free(sdma->iram_pool, (unsigned long)buf_virt, PAGE_BYTES);

	clk_disable(sdma->clk_ipg);
	clk_disable(sdma->clk_ahb);

	return ret < 0 ? ret : PAGE_BYTES-1;  // -1 is to shush warning about transferring a full page.
}

static ssize_t show_sdma_rom(struct device *dev, struct device_attribute *attr, char *output) {
	struct platform_device *pdev = to_platform_device(dev);
	struct sdma_engine *sdma = platform_get_drvdata(pdev);
	return dump_sdma_page(sdma, 0, output);
}

static ssize_t show_sdma_context_ram(struct device *dev, struct device_attribute *attr, char *output) {
	struct platform_device *pdev = to_platform_device(dev);
	struct sdma_engine *sdma = platform_get_drvdata(pdev);
	return dump_sdma_page(sdma, 2, output);
}

static ssize_t show_sdma_script_ram(struct device *dev, struct device_attribute *attr, char *output) {
	struct platform_device *pdev = to_platform_device(dev);
	struct sdma_engine *sdma = platform_get_drvdata(pdev);
	return dump_sdma_page(sdma, 3, output);
}

static DEVICE_ATTR(sdma_rom, S_IRUGO, show_sdma_rom, NULL);
static DEVICE_ATTR(sdma_context_ram, S_IRUGO, show_sdma_context_ram, NULL);
static DEVICE_ATTR(sdma_script_ram, S_IRUGO, show_sdma_script_ram, NULL);
```

Then, somewhere in probe, add the following:

```c
 	device_create_file(sdma->dev, &dev_attr_sdma_rom);
   	device_create_file(sdma->dev, &dev_attr_sdma_context_ram);
   	device_create_file(sdma->dev, &dev_attr_sdma_script_ram);
```

(It should be noted that one probably wouldn't abuse sysfs this way for production code, but this is just hacking.)

## Disassembling the Scripts

Once those attributes are in place, you should be able to find the sdma node in /sys, copy those sysfs files to normal files, and disassemble them.  You'll find some interesting stuff!  

I used a slightly modified version of the disassembler I found in a comment on Eli's blog post.  It's by "Exslestonec", but I can't find too much more online.  But whoever you are, you have my gratitude, and if you'd like a linkback or other credit, please get in touch!  My modified version is [here](/assets/other/sdma_disam.pl).

However, before we start reading the disassembled code, I should mention that you'll want to familiarize yourself with the SDMA's Functional Units.  These are two peripherals on the SDMA, which are the only way for the SDMA to read and write over the AXI bus.  They are accessed via two dedicated instructions: LDF and STF.  When you see those instructions below, keep in mind those are AXI bus reads and writes.  You may want to familiarize yourself with those units by reading the "Functional Units" chapter of the reference manual.  Or just take my word for it!

Here's my annotated disassembly of mcu_2_ecspi:

```assembly
mcu_2_ecspi:
    jsr        485                      # 6144  # subroutine loads BD, sets r5 = buf remaining
    ld         r7, (r3, 0x1b)           # 6145  # r7 = "burst length"
    ld         r2, (r3, 0x1e)           # 6146  # r2 = "BD buffer addr"
    stf        r2, 1                    # 6147  # MSA = r2 in incr mode
    ld         r2, (r3, 0x1f)           # 6148  # r2 = *0x701f (shp_addr)
    stf        r2, 211                  # 6149  # PDA = shp_addr (32b, frozen mode)
xfer_loop:
    ld         r2, (r3, 0x1f)           # 6150  # r2 = *0x701f (shp_addr, again, nice.)
    addi       r2, 0x1c                 # 6151  # ECSPIx_TXDATA + 0x1c == ECSPIx_TESTREG
    stf        r2, 195                  # 6152  # PSA in 32b frozen mode
    ldf        r2, 232                  # 6153  # PD, prefetch
    revblo     r2                       # 6154  # get RXCNT in low order bits
    andi       r2, 0xff                 # 6155  # mask off other stuff
    ldi        r0, 0x30                 # 6156  # r0 = 48
    cmplt      r2, r0                   # 6157  # if RXCNT >= 48
    bf         63 (%6222)               # 6158  #    then goto 6222
    mov        r0, r7                   # 6159  # r0 = r7 (burst length)
    bclri      r0, 0x1f                 # 6160  # clear high bit of burst length (??)
    cmplt      r0, r5                   # 6161  # if burst_length < buf_remaining:
    bt         1 (%6164)                # 6162  #    goto 6164
    mov        r0, r5                   # 6163  # r0 = burst_length
    sub        r5, r0                   # 6164  # buf_remaining -= burst_length
    st         r5, (r3, 0x1d)           # 6165  # scratch 1d = r5
    btsti      r4, 0x18                 # 6166  # ** Truth table for mode bits
    bt         3 (%6171)                # 6167  # | b24  b25
    btsti      r4, 0x19                 # 6168  # |  n
    bt         28 (%6198)               # 6169  # |  n    y,  goto mode_16b
    bf         32 (%6203)               # 6170  # |  n    n,  goto mode_32b
    btsti      r4, 0x19                 # 6171  # |  y
    bf         21 (%6194)               # 6172  # |  y    n,  goto mode_8b
    ld         r6, (r6, 0x1d)           # 6173  # |  y    y,  24b mode.  fall through...

# 24b mode is tricky.
# it takes steps to avoid reading unaligned halfwords,
# so it must choose whether to read 8- or 16-bit words,
# depending on whether the number of bytes remaining is odd or even.
    btsti      r6, 0x0                  # 6174  # test if even
    bt         5 (%6181)                # 6175  #     if so, goto 6181
    ldf        r5, 9                    # 6176  # read 2 bytes
    bsf        51 (%6229)               # 6177  #
    ldf        r2, 10                   # 6178  # read 1 bytes
    bsf        49 (%6229)               # 6179  #
    jmp        6185                     # 6180  # goto byte combiner 
    ldf        r2, 10                   # 6181  # read 1 byte
    bsf        46 (%6229)               # 6182  # 
    ldf        r5, 9                    # 6183  # read 2 bytes
    bsf        44 (%6229)               # 6184  #
    rorb       r5                       # 6185  # combine read entries
    rorb       r5                       # 6186  # 
    or         r2, r5                   # 6187  #
    stf        r2, 200                  # 6188  # send to peripheral
    bdf        39 (%6229)               # 6189  #
    subi       r0, 0x3                  # 6190  # 3 less bytes to read
    cmpeqi     r0, 0x0                  # 6191  #
    bf         -19 (%6174)              # 6192  # not done, go back
    jmp        6209                     # 6193  # done!
    
mode_8b:
    loop       2, 0                     # 6194
    ldf        r2, 9                    # 6195
    stf        r2, 200                  # 6196
    jmp        6208                     # 6197
mode_16b:
    lsr1       r0                       # 6198
    loop       2, 0                     # 6199
    ldf        r2, 10                   # 6200
    stf        r2, 200                  # 6201
    jmp        6208                     # 6202
mode_32b:
    lsr1       r0                       # 6203
    lsr1       r0                       # 6204
    loop       2, 0                     # 6205
    ldf        r2, 11                   # 6206
    stf        r2, 200                  # 6207

cleanup:  # T=true iff loop xfer success
    bf         20 (%6229)               # 6208
    stf        r5, 223                  # 6209  # PDA changes to 32-bit (should be nop)
    bdf        18 (%6229)               # 6210  #
    btsti      r7, 0x1f                 # 6211  # test high bit of burst length
    bt         9 (%6222)                # 6212  # if true (when??) goto 6222
    ld         r2, (r3, 0x1f)           # 6213  # r2 = shp_addr
    addi       r2, 0x4                  # 6214  # r2 = shp_addr + 4  (=ECSPIx_CONREG)
    stf        r2, 195                  # 6215  # set PSA = CONREG, 32b frozen mode
    stf        r2, 211                  # 6216  # set PDA = CONREG, 32b frozen mode
    ldf        r2, 200                  # 6217  # r2 = *CONREG
    ori        r2, 0x4                  # 6218  # r2 |= XCH
    stf        r2, 200                  # 6219  # *CONREG = r2
    ld         r2, (r3, 0x1f)           # 6220  # r2 = shp_addr
    stf        r2, 211                  # 6221  # PDA = shp_addr
    done       0                        # 6222  # yield, no interrupt
    ld         r5, (r3, 0x1d)           # 6223  # r5 = buf_remaining
    cmpeqi     r5, 0x0                  # 6224  # if buf_remaining == 0
    bt         7 (%6233)                # 6225  #   goto 6233 (loads next bd)
    jsr        508                      # 6226  # else call 508
    ld         r7, (r3, 0x1b)           # 6227  # restore r7 from proc 508
    jmp        6150                     # 6228  # goto xfer_loop

handle_fault:
    clrf       0                        # 6229
    stf        r0, 204                  # 6230
    stf        r0, 12                   # 6231
    jsr        533                      # 6232  # Fail the script

bd_done:
    jsr        524                      # 6233  # buf_remaining == 0, load next BD
    jmp        6145                     # 6234  # goto main loop.
```

Aha, so they are doing some interesting stuff in there, with special handling the case where there's at least 48 entries in the TXFIFO.  In this case they yield to other scripts.  That must be the fix we want.

You'll notice some jumps to the ROM in there as well.  There's some useful routines in ROM, and I'll show my annotations for these as well.

Here's the common initialization function first called by `mcu_2_ecspi`:

```assembly
    ldi        r3, 0x70                 # 485
    revblo     r3                       # 486
    ld         r3, (r3, 0x2)            # 487  # r3 = CCP
    st         r7, (r3, 0x1b)           # 488  # scratch 1b = r7
    ldrpc      r7                       # 489  # r7 = rpc
    st         r0, (r3, 0x1a)           # 490  # scratch 1a = r0
    mov        r0, r3                   # 491  # r0 = r3
    st         r6, (r3, 0x1f)           # 492  # scratch 1f = r6
    jsr        316                      # 493  # 316 is "r3 = CBD ptr, test 0"


    bt         36 (%531)                # 494  # if CBDptr is 0, goto 531
    st         r2, (r0, 0x18)           # 495  # scratch 18 = r2
    st         r3, (r0, 0x19)           # 496  # scratch 19 = r3
    jsr        334                      # 497  # load_cbd_to_r456

    bf         32 (%531)                # 498  # if err, goto 531
    mov        r3, r0                   # 499  # r3 = 0x7000
    st         r5, (r0, 0x1e)           # 500  # scratch 1e = r5
    ldi        r5, 0xff                 # 501  # 
    revblo     r5                       # 502  #
    addi       r5, 0xff                 # 503  # r5 = 0xffff
    and        r5, r4                   # 504  # r5 = bd.count
    cmpeqi     r5, 0x0                  # 505  # if count == 0
    bt         19 (%526)                # 506  #   goto 526
    jmp        510                      # 507  # jump 510
    st         r7, (r3, 0x1b)           # 508  # scratch 1b = r7
    ldrpc      r7                       # 509  # r7 = rpc
check_events:
    ldi        r6, 0x70                 # 510
    revblo     r6                       # 511
    ld         r2, (r6, 0x5)            # 512  # r2 = set events register
    and        r2, r1                   # 513  # r2 &= r1
    cmpeqi     r2, 0x0                  # 514  # if no requested events set
    bf         7 (%523)                 # 515  #    goto 523  (normal path?)
    ld         r2, (r6, 0x1f)           # 516  # r2 = scratch 1f (shifted shp addr)
    ld         r0, (r3, 0x1a)           # 517  # r0 = scratch 1a (events2? unused)
    and        r2, r0                   # 518  # AND with zero?
    cmpeqi     r2, 0x0                  # 519  # always true, i think.
    bf         2 (%523)                 # 520  # then go to 523? (return to caller)
    done       4                        # 521  # some requsted events set, yield, set unset EP bit
    jmp        510                      # 522  # try 510 again
    jmpr       r7                       # 523  # return to caller (508?)    
```

Some interesting stuff there.  You can see the script loading the channel control block from main memory, loading the current buffer destriptor, checking its count, and checking to see if any events for this script have already occurred.  Fascinating stuff!  When we created our version of events, we should definitely make use of this code.

For comparison, let's look at the disassembly of the generic mcu_2_shp script, which I found to not work correctly for ECSPI.  Comparing is educational!

```assembly
mcu_2_shp:
# common setup
    jsr        473                      # 962
    jsr        485                      # 963
# assumptions at this point:
# r5 = buffer descriptor count remaining# 
    ld         r7, (r3, 0x1b)           # 964 # r7 = scratch 1b "burst length"
    ld         r2, (r3, 0x1e)           # 965 # r2 = scratch 1e "buffer addr"
    stf        r2, 1                    # 966 # MSA = r2 in incr mode
    mov        r0, r7                   # 967 # r0 = r7 "burst length"
    cmplt      r0, r5                   # 968 # if burst_len < buf_remaining:
    bt         1 (%971)                 # 969 #    goto 971
    mov        r0, r5                   # 970 # burst_len = buf_remaining
    sub        r5, r0                   # 971 # buf_remaining -= burst_len
    st         r5, (r3, 0x1d)           # 972 # scratch 1d = r5 (buf_remaining)
    ld         r6, (r3, 0x1f)           # 973 # r6 = shp_addr_shftd
    btsti      r4, 0x18                 # 974 # ** Truth table for cmd bits
    bt         3 (%979)                 # 975 # | if BIT(24), goto 979
    btsti      r4, 0x19                 # 976 # |
    bt         33 (%1011)               # 977 # | if !BIT(24) and BIT(25) goto 1011
    bf         37 (%1016)               # 978 # | if !BIT(24) and !BIT(25) goto 1016 (32b mode)
    btsti      r4, 0x19                 # 979 # | BIT(24) set, so
    bf         26 (%1007)               # 980 # | if BIT(24) and !BIT(25), goto 1007
    ldi        r3, 0x70                 # 981 # | 24 Bit Mode! (BIT(24) and BIT(25) both set)
    revblo     r3                       # 982 # 
    ld         r3, (r3, 0x1d)           # 983 # r3 = scratch 1d (buf_remaining)
# 24b mode is tricky.
# it takes steps to avoid reading unaligned halfwords,
# so it must choose whether to read 8- or 16-bit words,
# depending on whether the number of bytes remaining is odd or even.
    btsti      r3, 0x0                  # 984 # 
    bt         5 (%991)                 # 985 # if buf_remaining is odd, goto 991 
    ldf        r5, 9                    # 986 # load MD byte into r5
    bsf        41 (%1029)               # 987 #     if source fault, goto 1029
    ldf        r2, 10                   # 988 # load MD halfword into r2
    bsf        39 (%1029)               # 989 #     if source fault, goto 1029 
    jmp        995                      # 990 # goto 995

    					#     # ** buf remaining is odd
    ldf        r2, 10                   # 991 # r2 = load MD halfword 
    bsf        36 (%1029)               # 992 #     if source fault, goto 1029
    ldf        r5, 9                    # 993 # r5 = load MD byte
    bsf        34 (%1029)               # 994 #     if source fault, goto 1029
    rorb       r5                       # 995 # ** combine read words into one
    rorb       r5                       # 996 # |
    or         r2, r5                   # 997 # r2 = r2 | (r5 << 16)
    st         r2, (r6, 0x0)            # 998 # *shp_addr_shifted = r2 (store mcu word to shp)
    bdf        29 (%1029)               # 999 # if data fault, goto 1029
    subi       r0, 0x3                  # 1000 # r0 -= 3
    cmpeqi     r0, 0x0                  # 1001 # if r0 != 0
    bf         -19 (%984)               # 1002 #   goto 984 (loop to handle next 24b word)
# done reading 24b burst
    ldi        r3, 0x70                 # 1003 
    revblo     r3                       # 1004 #
    ld         r3, (r3, 0x2)            # 1005 # r3 = *0x7002 (CCP)
    jmp        1022                     # 1006 # goto loop 

# 8b mode!
    loop       2, 0                     # 1007 # LOOP START - r0 is byte count
    ldf        r2, 9                    # 1008 # | r2 = load MD byte
    st         r2, (r6, 0x0)            # 1009 # | *(shp_addr_shifted) = r2
    jmp        1021                     # 1010 # goto common loop cleanup

# 16b mode!
    lsr1       r0                       # 1011 # r0 div by 2
    loop       2, 0                     # 1012 # LOOP START
    ldf        r2, 10                   # 1013 # | r2 = load MD halfword 
    st         r2, (r6, 0x0)            # 1014 # | *shp_addr_shifted = r2
    jmp        1021                     # 1015 # goto common loop cleanup

# 32b mode!
    lsr1       r0                       # 1016 #
    lsr1       r0                       # 1017 # r0 = r0/4
    loop       2, 0                     # 1018 # LOOP START - r0 times
    ldf        r2, 11                   # 1019 # | r2 = load MD 32b word
    st         r2, (r6, 0x0)            # 1020 # | *(shp_addr_shifted) = r2

# common loop cleanup
    bf         7 (%1029)                # 1021 # if loop faulted, goto 1029
    done       0                        # 1022 # yield to strictly higher priority channel
    ld         r5, (r3, 0x1d)           # 1023 # r5 = scratch 1d (buf remaining)
    cmpeqi     r5, 0x0                  # 1024 # if buf remaining == 0
    bt         6 (%1032)                # 1025 #    goto 1032
    jsr        508                      # 1026 # subroutine 508
    ld         r7, (r3, 0x1b)           # 1027 # r7 = burst length
    jmp        967                      # 1028 # goto 967 (handle next burst)

# ** Source Faults goto here (above)
    clrf       0                        # 1029 # clear fault flags
    stf        r0, 12                   # 1030 # clear MS error flag
    jsr        533                      # 1031 # common bail_out()
# buf_remaining == 0
    jsr        524                      # 1032 # call load next bd
    jmp        964                      # 1033 # jmp to main mcu_2_shp loop
    
```

There's another code block in the ROM which I want to call out, which is the first thing called by the mcu_2_shp code, but is absent from mcu_2_ecspi:

```assembly
    ldi        r4, 0xf                  # 473
    revblo     r4                       # 474
    addi       r4, 0xff                 # 475  # r4 = 0xfff
    mov        r5, r6                   # 476  # r5 = shp_addr
    and        r6, r4                   # 477  # r6 = shp_addr & 0xfff
    lsr1       r5                       # 478
    lsr1       r5                       # 479
    lsr1       r5                       # 480  
    lsr1       r5                       # 481  # r5 = shp_addr >> 4
    andn       r5, r4                   # 482  # r5 = (shp_addr >> 4) & 0xfffff000
    or         r6, r5                   # 483  # r6 = (shp_addr & 0xfff) | r5
    ret                                 # 484
```

This odd-looking little routine at PC offset 473 takes the high 16 bits of r6 and shifts them right by 4 bits, preserving the low 12 bits.  What could it possibly be up to?  The answer lies in the way the SPBA is addressed on the SDMA.  The SDMA has SPBA-accessible peripherals included directly into its memory map.  These peripherals are also accessible via main memory.  However, they don't have the same base address on both buses.  However, there's a trick - the 16-bit address of any of the peripherals on the shared bus has a base address which *just happens* to begin with the 5th nibble of the main bus address.  Behold:

| Peripheral | Main Bus Address | SDMA Address |
| -----------|------------------|--------------|
| ECSPI1     | 0x308**2**0000   | 0x2000       |
| ECSPI2     | 0x308**3**0000   | 0x3000       |
| ECSPI3     | 0x308**4**0000   | 0x4000       |
| UART1	     | 0x308**6**0000   | 0x6000       |
| UART3	     | 0x308**8**0000   | 0x8000       |
| etc... |

If you want to explore further, check out the "DMA memory map" section of the reference manual, and compare it to the main bus base addresses of the peripherals.  Quite neatly done!

So, our odd little friend at SDMA PC 473 maps a peripheral address from main memory into its SDMA address.  A very useful routine indeed.  We'll make use of it for sure.

We are so close!  Let's bring it all home in [Part 5](/sdma-hacking-part-5.html).
