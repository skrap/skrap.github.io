---
title:  "SDMA Hacking Part 2: Creating Custom Scripts"
tags: code sdma
---
This is part 2 of this series of posts on programming the i.MX SDMA Engine.  The full series is as follows:

* [Part 1: Introduction](/sdma-hacking/part-1.html)
* Part 2: Creating Custom Scripts (this part)
* [Part 3: Script Parameters](/sdma-hacking/part-3.html)
* [Part 4: Standard ROM Scripts](/sdma-hacking/part-4.html)
* [Part 5: Custom SPI Script](/sdma-hacking/part-5.html)


Ok, by the end of this entry, you'll know everything you need in order to run your own SDMA scripts from Linux!  Let's dig right in.

## A Simple Script

The next step is to create a custom script, and modify the SDMA driver to allow us to run it.  For this example, we'll use the sample script from Eli Billauer's blog:

```
start:
    ldi r0, 4        # r0 = 4 
    loop exit, 0    # loop 4 times, then goto 'exit'
    st r4, (r5, 0)  #   *r5 = r4
    addi r5, 1        #   r5 += 1
    addi r4, 0x10   #   r4 += 0x10
exit:
    done 3          # interrupt ARM core, pause script
    addi r4, 0x40   # r4 += 0x40
    ldi r3, 0       # r3 = 0
    cmpeqi r3, 0    # if r3 == 0 (Always true)
    bt start        #    goto 'start'
```

I've annotated the above in C-ish code, for the curious.  All you really need to know is that the script writes to some SDMA-local memory, and signals the ARM core.  Nothing too useful, but we can have Linux receive the interrupt, and be fairly sure that the script is running.  A good beginning.

## Assembler

I should pause here to make a note about the toolchain for building SDMA binaries.  I hear that there is a "real" C compiler somewhere in NXP-land, and the i.MX25 Reference Manual even makes reference to an API which custom scripts can call.  However, none of that is available any more, or is at a minimum locked away behind NDAs.

Luckily, the instruction set is quite simple, and Eli Billauer wrote a perfectly capable assembler in Perl, which I copied and altered so that it would produce raw script binaries.  My version is available [here](/assets/other/sdma_asm.pl).  Typical usage is something like:
```
./sdma_asm.pl first-script.asm > /tmp/out.asm
```

This will produce output to stderr for you to look at, and also write the assembled binary to /tmp/out.asm.

## Running Custom Scripts with the Linux SDMA Driver

The Linux SDMA driver doesn't have native support for running custom scripts.  But it's not too hard to add, so let's do it!  I made the following changes against Linux 4.1.15 from the [linux-fslc](https://github.com/Freescale/linux-fslc) repository's 4.1-2.0.x-imx branch.  But they could be easily adapted to other situations.

Lets' make running our own scripts a bit easier by reserving a channel for our use.  Channel 0 is already reserved for special purposes by the SDMA and the driver, so let's piggyback on that handling, with this change to `sdma_probe()`:

```c
    if (i > 1)  // reserve channels 0 and 1.
        vchan_init(&sdmac->vc, &sdma->dma_device);
```

If we are going to load our own scripts into RAM, we will want to record the address of the free RAM after the existing user scripts have been loaded.  **NOTE** that I'm assuming the existing RAM scripts don't make use of the SDMA RAM are for anything.  This might totally be wrong, and it might overwrite your custom scripts, or vice versa.  Horrible things could happen.  Probably don't do this in production.  But for hacking around, go for it!

Let's add a `s32 user_script_paddr` to the `struct sdma_engine`, and populate it in `sdma_load_firmware` like so:

```c
    dev_info(sdma->dev, "loaded firmware %d.%d\n",
            header->version_major,
            header->version_minor);

    sdma->user_script_paddr = addr->ram_code_start_addr + (header->ram_code_size+1)/2;
```

That funky math with the size is to round it up to the next 16-bit boundary.  Just precautionary.

Then, with that address in place, we can write some code to expose a sysfs entry which accepts code from our assembler and loads it into RAM at the address recorded above:

```c
static DEVICE_ATTR(user_script, S_IWUSR, NULL, store_user_script);

static ssize_t store_user_script(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct platform_device *pdev = to_platform_device(dev);
    struct sdma_engine *sdma = platform_get_drvdata(pdev);
    int res;

    if (sdma->user_script_paddr == 0) {
        res = -EINVAL;
    }

    clk_enable(sdma->clk_ipg);
    clk_enable(sdma->clk_ahb);
    res = sdma_load_script(sdma, buf, count, sdma->user_script_paddr);
    clk_disable(sdma->clk_ipg);
    clk_disable(sdma->clk_ahb);

    return (res == 0) ? count : res;
}
```

You'll also need to create the sysfs entry somewhere in sdma_probe like this: `device_create_file(sdma->dev, &dev_attr_user_script)`.

Oh, and we'll need some way to set the registers of the channel context.  So let's do those via sysfs as well:

```c
static struct {
    u32 r[8];
} user_regs = {};
static DEVICE_ULONG_ATTR(reg_r0, S_IRUGO|S_IWUSR, user_regs.r[0]);
static DEVICE_ULONG_ATTR(reg_r1, S_IRUGO|S_IWUSR, user_regs.r[1]);
static DEVICE_ULONG_ATTR(reg_r2, S_IRUGO|S_IWUSR, user_regs.r[2]);
static DEVICE_ULONG_ATTR(reg_r3, S_IRUGO|S_IWUSR, user_regs.r[3]);
static DEVICE_ULONG_ATTR(reg_r4, S_IRUGO|S_IWUSR, user_regs.r[4]);
static DEVICE_ULONG_ATTR(reg_r5, S_IRUGO|S_IWUSR, user_regs.r[5]);
static DEVICE_ULONG_ATTR(reg_r6, S_IRUGO|S_IWUSR, user_regs.r[6]);
static DEVICE_ULONG_ATTR(reg_r7, S_IRUGO|S_IWUSR, user_regs.r[7]);

```

Those will need to be registered in probe just like the user script.

In order to run the program, you'll need a way to trigger it once it's been loaded.  Let's do that via sysfs as well:

```c
static ssize_t trigger_user_script(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
    struct platform_device *pdev = to_platform_device(dev);
    struct sdma_engine *sdma = platform_get_drvdata(pdev);
    const int channel = 1;
    struct sdma_channel *sdmac = &sdma->channel[channel];
    struct sdma_buffer_descriptor *bd0 = sdma->bd0;
    struct sdma_context_data *context = sdma->context;
    unsigned long flags;
    int ret;
    int i;

    clk_enable(sdma->clk_ipg);
    clk_enable(sdma->clk_ahb);

    sdma_disable_channel(&sdmac->vc.chan);
    sdma_config_ownership(sdmac, false, true, false);

    spin_lock_irqsave(&sdma->channel_0_lock, flags);

    memset(context, 0, sizeof(*context));
    context->channel_state.pc = sdma->user_script_paddr;

    for (i = 0; i < ARRAY_SIZE(user_regs.r); i++) {
        context->gReg[i] = user_regs.r[i];
    }

    bd0->mode.command = C0_SETDM;
    bd0->mode.status = BD_DONE | BD_INTR | BD_WRAP | BD_EXTD;
    bd0->mode.count = sizeof(*context) / 4;
    bd0->buffer_addr = sdma->context_phys;
    bd0->ext_buffer_addr = 2048 + (sizeof(*context) / 4) * channel;
    ret = sdma_run_channel0(sdma);

    spin_unlock_irqrestore(&sdma->channel_0_lock, flags);

    if (ret == 0) {
        unsigned long timeout = 500;

        dev_info(sdma->dev, "will run script ch %u", channel);

        sdmac->context_loaded = true;
        sdma->channel_control[channel].base_bd_ptr = 0;
        sdma->channel_control[channel].current_bd_ptr = 0;
        sdma_set_channel_priority(&sdma->channel[channel], MXC_SDMA_DEFAULT_PRIORITY);
        sdma_enable_channel(sdma, channel);

        while (!(ret = readl_relaxed(sdma->regs + SDMA_H_INTR) & BIT(1))) {
            if (timeout-- <= 0)
                break;
            udelay(1);
        }

        if (ret == 0) {
            writel_relaxed(ret, sdma->regs + SDMA_H_INTR);
        }
        /* Set bits of CONFIG register with dynamic context switching */
        if (readl(sdma->regs + SDMA_H_CONFIG) == 0)
            writel_relaxed(SDMA_H_CONFIG_CSM, sdma->regs + SDMA_H_CONFIG);

        dev_info(sdma->dev, "result of script ch %u:", channel);
        snapshot(sdma, channel);
    } else {
        dev_err(sdma->dev, "failed to load context: %d", ret);
        clk_disable(sdma->clk_ipg);
        clk_disable(sdma->clk_ahb);
    }

    return (ret == 0) ? count : ret;
}
```

That seems cool.  It won't compile as-is, though, because it calls this `snapshot` method.  It's a debugging method which I stole from Eli's page and expanded to include more registers.  Let's dive into a bit more detail on that.

## Context Snapshot for Debugging

The SDMA engine only runs one channel at a time.  Each channel's script must explicitly yield its time for other scripts to have a chance to run.  When a script yields and the SDMA switches to another script, it preserves the registers of the yielding script to SDMA internal RAM in what's called a "channel context".  The layout of this context is specified in the reference manual.  In the iMX7D manual, it's in Table 7-13, "Layout of a Channel Context in Memory for SDMA", but it appears in each i.MX version's manual in more or less the same form.

We can take advantage of this context saving by actually downloading the context from the SDMA to the CPU for examination.  This gives us a good idea of what the SDMA was doing when it switched contexts, including the PC, error flags, general and scratch registers, and state of the various peripherals (more on the peripherals later).


```c
static int snapshot(struct sdma_engine *sdma, int channel) {
    struct sdma_buffer_descriptor *bd0 = sdma->bd0;
    struct sdma_context_data *context = sdma->context;
    unsigned long flags;
    int ret;
    int i;

    const char *regnames[] = {
            "r0", "r1", "r2", "r3",
            "r4", "r5", "r6", "r7",
            "mda", "msa", "ms", "md",
            "pda", "psa", "ps", "pd",
            "ca", "cs", "dda", "dsa",
            "ds", "dd", "sc18", "sc19",
            "sc1A", "sc1B", "sc1C", "sc1D",
            "sc1E", "sc1F" };


    spin_lock_irqsave(&sdma->channel_0_lock, flags);
    memset(context, 0, sizeof(*context));
    bd0->mode.command = C0_GETDM;
    bd0->mode.status = BD_DONE | BD_INTR | BD_WRAP | BD_EXTD;
    bd0->mode.count = sizeof(*context) / 4;
    bd0->buffer_addr = sdma->context_phys;
    bd0->ext_buffer_addr = 2048 + (sizeof(*context) / 4) * channel;
    ret = sdma_run_channel0(sdma);
    spin_unlock_irqrestore(&sdma->channel_0_lock, flags);

    dev_info(sdma->dev, "pc=%04x rpc=%04x spc=%04x epc=%04x\n",
       context->channel_state.pc,
       context->channel_state.rpc,
       context->channel_state.spc,
       context->channel_state.epc
     );

    dev_info(sdma->dev, "Flags: t=%d sf=%d df=%d lm=%d\n",
       context->channel_state.t,
       context->channel_state.sf,
       context->channel_state.df,
       context->channel_state.lm
     );

    for (i = 0; i + 4 < ARRAY_SIZE(regnames); i+= 4) {
        u32 *ptr = &context->gReg[0];
        dev_info(sdma->dev, "%s:0x%x %s:0x%x %s:0x%x %s:0x%x",
                regnames[i], ptr[i],
                regnames[i+1], ptr[i+1],
                regnames[i+2], ptr[i+2],
                regnames[i+3], ptr[i+3]);
    }
    {
        u32 *ptr = &context->gReg[0];
        dev_info(sdma->dev, "%s:0x%x %s:0x%x",
                regnames[i], ptr[i],
                regnames[i+1], ptr[i+1]);
    }

    return ret;
}
```

Armed with that info and code, you should be able to write your own SDMA scripts, load them up, and watch them run!   You'll probably want the [assembler](/assets/other/sdma_asm.pl), which is a modified version of Eli's assembler.

It outputs annotated assembly to STDERR, while writing raw binary to STDOUT.  A bit awkward, I know, but it works well if you use it like so:

```
$ ./sdma_asm.pl my_great_script.asm > /tmp/asm.out
```

Go on, play around with it!  I bet you can find something fun to do.

Once you're in the mood for more reading, check out [Part 3](/sdma-hacking/part-3.html).
