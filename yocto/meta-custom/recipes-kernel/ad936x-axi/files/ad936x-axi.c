// SPDX-License-Identifier: GPL-2.0-only
/*
 * ad936x-axi - Platform driver for the custom AD936x AXI FPGA peripheral.
 *
 * Replaces /dev/mem access with a proper driver providing:
 *   - Cached mmap of the RX DDR buffer (vs uncached /dev/mem)
 *   - read() returns {rd_offset, hw_wr_offset, lost_bytes} and invalidates cache
 *   - open/close manage FPGA enable/disable
 */

#include <linux/atomic.h>
#include <linux/dma-mapping.h>
#include <linux/hrtimer.h>
#include <linux/io.h>
#include <linux/ioctl.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/platform_device.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#include <linux/debugfs.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/seq_file.h>

/* Register layout — must match FPGA RTL (ad936x_axi.vhd) */
struct ad936x_axi_regs {
    u32 info;        /* 0x00  read-only, upper 16 bits = 0xAD93 */
    u32 ctrl;        /* 0x04  ctrl bits, see below definitions */
    u32 tx_underrun; /* 0x08  TX underrun counter */
    u32 rx_overflow; /* 0x0C  RX overflow counter */
    u32 rx_buf_base; /* 0x10  DMA base physical address */
    u32 rx_buf_size; /* 0x14  DMA buffer size in bytes */
    u32 _reserved;   /* 0x18 */
    u32 rx_buf_wr;   /* 0x1C  FPGA write pointer (byte offset from base) */
    u32 tx_buf_base; /* 0x20  TX buffer base physical address */
    u32 tx_buf_size; /* 0x24  TX buffer size in bytes */
    u32 tx_buf_rd;   /* 0x28  FPGA TX read pointer (byte offset) */
    u32 tx_buf_wr;   /* 0x2C  Software write pointer */
};

#define AD936X_CTRL_RESET BIT(0)
#define AD936X_CTRL_RX_ENABLE BIT(1)
#define AD936X_CTRL_TX_ENABLE BIT(2)

#define AD936X_INFO_MAGIC 0xAD93

#define AD936X_AXI_IOC_MAGIC 'a'
#define AD936X_AXI_IOC_GET_RX_BUFSIZE _IOR(AD936X_AXI_IOC_MAGIC, 0, __u32)
#define AD936X_AXI_IOC_GET_BLOCKSIZE _IOR(AD936X_AXI_IOC_MAGIC, 1, __u32)
#define AD936X_AXI_IOC_GET_TX_BUFSIZE _IOR(AD936X_AXI_IOC_MAGIC, 2, __u32)
#define AD936X_AXI_IOC_ENABLE _IO(AD936X_AXI_IOC_MAGIC, 3)

static unsigned int rx_block_size = 65536;
module_param(rx_block_size, uint, 0444);

static unsigned int timer_period_ms = 1;
module_param(timer_period_ms, uint, 0444);

struct ad936x_axi {
    struct device *dev;
    struct ad936x_axi_regs __iomem *regs;
    // TX buffer
    phys_addr_t txbuf_phys;
    size_t txbuf_size;
    size_t txbuf_size_max;
    u32 tx_wr_ptr; /* software-tracked TX write pointer */
    // RX buffer
    phys_addr_t rxbuf_phys;
    size_t rxbuf_size;
    size_t rxbuf_size_max;
    u32 rd_ptr;
    atomic_t in_use; /* single-open guard */
    bool closing;

    struct hrtimer timer;
    wait_queue_head_t tx_wq;
    wait_queue_head_t rx_wq;
    atomic_t blocks_ready; /* inc by timer, dec by read */
    u32 timer_wr_ptr;      /* timer's last accepted wr pointer (block-aligned) */
    struct miscdevice misc;

    /* debugfs stats */
    struct dentry *debugfs_dir;
    ktime_t open_time;
    ktime_t last_read_time;
    u64 total_bytes_written;
    u32 prev_wr_ptr;
    u32 buf_used_peak;
    u64 read_count;
    u64 overrun_bytes;
};

static struct ad936x_axi *file_to_priv(struct file *f) {
    return container_of(f->private_data, struct ad936x_axi, misc);
}

static enum hrtimer_restart ad936x_axi_timer(struct hrtimer *t) {
    struct ad936x_axi *priv = container_of(t, struct ad936x_axi, timer);
    u32 wr_ptr = readl(&priv->regs->rx_buf_wr);
    u32 delta;

    if (priv->rxbuf_size > 0) {
        // rxbuf_size is set in mmap(), while hrtimer is created on open()
        if (wr_ptr >= priv->timer_wr_ptr)
            delta = wr_ptr - priv->timer_wr_ptr;
        else
            delta = priv->rxbuf_size - priv->timer_wr_ptr + wr_ptr;

        u32 new_blocks = delta / rx_block_size;
        if (new_blocks > 0) {
            u32 advance = new_blocks * rx_block_size;
            priv->timer_wr_ptr = (priv->timer_wr_ptr + advance) % priv->rxbuf_size;
            atomic_add(new_blocks, &priv->blocks_ready);
            wake_up(&priv->rx_wq);
        }
    }

    wake_up(&priv->tx_wq);

    hrtimer_forward_now(t, ms_to_ktime(timer_period_ms));
    return HRTIMER_RESTART;
}

static int ad936x_axi_open(struct inode *inode, struct file *f) {
    struct ad936x_axi *priv = file_to_priv(f);

    /* Enforce single open — two processes sharing rd_ptr / FPGA state
     * would corrupt each other. */
    if (atomic_cmpxchg(&priv->in_use, 0, 1) != 0)
        return -EBUSY;

    /* Reset FPGA state */
    writel(AD936X_CTRL_RESET, &priv->regs->ctrl);

    /* Configure RX buffer location */
    writel(priv->rxbuf_phys, &priv->regs->rx_buf_base);

    /* Configure TX buffer location */
    writel(priv->txbuf_phys, &priv->regs->tx_buf_base);
    writel(0, &priv->regs->tx_buf_wr);
    priv->tx_wr_ptr = 0;

    /* Release reset, enable is performed via IOCTL_ENABLE */
    writel(0, &priv->regs->ctrl);

    /* Clear sizes so the timer guard (rxbuf_size > 0) holds until mmap re-establishes them */
    priv->rxbuf_size = 0;
    priv->txbuf_size = 0;

    /* Read actual hw pointer — FPGA may not zero rx_buf_wr on soft reset */
    u32 hw_wr = readl(&priv->regs->rx_buf_wr);

    priv->closing = false;
    priv->rd_ptr = 0;
    priv->timer_wr_ptr = hw_wr;
    atomic_set(&priv->blocks_ready, 0);
    init_waitqueue_head(&priv->tx_wq);
    init_waitqueue_head(&priv->rx_wq);
    hrtimer_init(&priv->timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
    priv->timer.function = ad936x_axi_timer;
    hrtimer_start(&priv->timer, ms_to_ktime(timer_period_ms), HRTIMER_MODE_REL);

    priv->open_time = ktime_get();
    priv->last_read_time = priv->open_time;
    priv->total_bytes_written = 0;
    priv->prev_wr_ptr = hw_wr;
    priv->buf_used_peak = 0;
    priv->read_count = 0;
    priv->overrun_bytes = 0;

    return 0;
}

struct ad936x_axi_rx_read {
    u32 rd;
    u32 hw_wr;
    u32 lost_bytes;
};

struct ad936x_axi_tx_write {
    u32 wr; /* byte offset, data is valid up to here */
};

static ssize_t ad936x_axi_read(struct file *f, char __user *buf, size_t count, loff_t *ppos) {
    struct ad936x_axi *priv = file_to_priv(f);
    struct ad936x_axi_rx_read resp = {};
    u32 wr_ptr;
    const u32 max_blocks = priv->rxbuf_size / rx_block_size;

    if (count < sizeof(resp))
        return -EINVAL;

    wait_event(priv->rx_wq, atomic_read(&priv->blocks_ready) > 0 || priv->closing);
    if (priv->closing)
        return -ENODEV;

    /* Overrun detection — reader fell behind, buffer has wrapped */
    if (atomic_read(&priv->blocks_ready) >= (int)max_blocks) {
        wr_ptr = readl(&priv->regs->rx_buf_wr);

        /* Snap rd_ptr to half-buffer behind wr_ptr, block-aligned */
        u32 half = priv->rxbuf_size / 2;
        u32 new_rd = (wr_ptr >= half) ? (wr_ptr - half) : (priv->rxbuf_size - half + wr_ptr);
        new_rd = (new_rd / rx_block_size) * rx_block_size;

        /* Compute lost bytes (distance from old rd_ptr to new rd_ptr) */
        if (new_rd >= priv->rd_ptr)
            resp.lost_bytes = new_rd - priv->rd_ptr;
        else
            resp.lost_bytes = priv->rxbuf_size - priv->rd_ptr + new_rd;

        priv->overrun_bytes += resp.lost_bytes;
        priv->rd_ptr = new_rd;
        atomic_sub(resp.lost_bytes / rx_block_size, &priv->blocks_ready);
    }

    atomic_dec(&priv->blocks_ready);
    wr_ptr = readl(&priv->regs->rx_buf_wr);

    /* Stats tracking */
    {
        u32 delta = (wr_ptr >= priv->prev_wr_ptr) ? (wr_ptr - priv->prev_wr_ptr)
                                                  : (priv->rxbuf_size - priv->prev_wr_ptr + wr_ptr);
        u32 used = (wr_ptr >= priv->rd_ptr) ? (wr_ptr - priv->rd_ptr)
                                            : (priv->rxbuf_size - priv->rd_ptr + wr_ptr);

        priv->total_bytes_written += delta;
        priv->prev_wr_ptr = wr_ptr;

        if (used > priv->buf_used_peak)
            priv->buf_used_peak = used;

        priv->last_read_time = ktime_get();
        priv->read_count++;
    }

    /* Invalidate cache for the block [rd .. rd+rx_block_size) */
    dma_sync_single_for_cpu(priv->dev, priv->rxbuf_phys + priv->rd_ptr, rx_block_size,
                            DMA_FROM_DEVICE);

    resp.rd = priv->rd_ptr;
    resp.hw_wr = wr_ptr;

    if (copy_to_user(buf, &resp, sizeof(resp)))
        return -EFAULT;

    /* Advance rd_ptr by one block, wrap at buffer end */
    {
        u32 next = priv->rd_ptr + rx_block_size;
        priv->rd_ptr = (next >= priv->rxbuf_size) ? 0 : next;
    }

    return sizeof(resp);
}

static ssize_t ad936x_axi_write(struct file *f, const char __user *buf, size_t count,
                                loff_t *ppos) {
    struct ad936x_axi *priv = file_to_priv(f);
    struct ad936x_axi_tx_write req;
    u32 old_wr, flush_len;
    if (count < sizeof(req))
        return -EINVAL;
    if (copy_from_user(&req, buf, sizeof(req)))
        return -EFAULT;
    if (req.wr >= priv->txbuf_size)
        return -EINVAL;

    wait_event(priv->tx_wq, ({
                   u32 rd = readl(&priv->regs->tx_buf_rd);
                   u32 used = (req.wr >= rd) ? (req.wr - rd) : (priv->txbuf_size - rd + req.wr);
                   used <= priv->txbuf_size - rx_block_size || priv->closing;
               }));
    if (priv->closing)
        return -ENODEV;

    old_wr = priv->tx_wr_ptr;
    if (req.wr >= old_wr)
        flush_len = req.wr - old_wr;
    else
        flush_len = priv->txbuf_size - old_wr + req.wr;

    if (flush_len > 0) {
        u32 to_end, chunk;
        to_end = priv->txbuf_size - old_wr;
        chunk = min_t(u32, flush_len, to_end);
        dma_sync_single_for_device(priv->dev, priv->txbuf_phys + old_wr, chunk, DMA_TO_DEVICE);
        if (flush_len > chunk)
            dma_sync_single_for_device(priv->dev, priv->txbuf_phys, flush_len - chunk,
                                       DMA_TO_DEVICE);
    }

    priv->tx_wr_ptr = req.wr;
    writel(req.wr, &priv->regs->tx_buf_wr);
    return sizeof(req);
}

static int ad936x_axi_mmap(struct file *f, struct vm_area_struct *vma) {
    struct ad936x_axi *priv = file_to_priv(f);
    unsigned long size = vma->vm_end - vma->vm_start;
    phys_addr_t phys;

    if (size % rx_block_size != 0)
        return -EINVAL;

    if (vma->vm_pgoff == 0) {
        /* RX buffer - read only */
        if (vma->vm_flags & VM_WRITE)
            return -EPERM;
        if (size > priv->rxbuf_size_max)
            return -EINVAL;
        priv->rxbuf_size = size;
        phys = priv->rxbuf_phys;
        writel(priv->rxbuf_size, &priv->regs->rx_buf_size);
    } else if (vma->vm_pgoff == 1) {
        /* TX buffer - read-write */
        if (size > priv->txbuf_size_max)
            return -EINVAL;
        priv->txbuf_size = size;
        phys = priv->txbuf_phys;
        writel(priv->txbuf_size, &priv->regs->tx_buf_size);
    } else {
        return -EINVAL;
    }

    vm_flags_set(vma, VM_DONTEXPAND | VM_DONTDUMP | VM_PFNMAP);

    /* Cached mapping — this is the whole point of this driver */
    return remap_pfn_range(vma, vma->vm_start, phys >> PAGE_SHIFT, size, vma->vm_page_prot);
}

static long ad936x_axi_ioctl(struct file *f, unsigned int cmd, unsigned long arg) {
    struct ad936x_axi *priv = file_to_priv(f);

    switch (cmd) {
    case AD936X_AXI_IOC_GET_RX_BUFSIZE:
        return put_user((__u32)priv->rxbuf_size_max, (__u32 __user *)arg);
    case AD936X_AXI_IOC_GET_BLOCKSIZE:
        return put_user((__u32)rx_block_size, (__u32 __user *)arg);
    case AD936X_AXI_IOC_GET_TX_BUFSIZE:
        return put_user((__u32)priv->txbuf_size_max, (__u32 __user *)arg);
    case AD936X_AXI_IOC_ENABLE: {
        u32 ctrl = 0;
        if (priv->rxbuf_size > 0)
            ctrl |= AD936X_CTRL_RX_ENABLE;
        if (priv->txbuf_size > 0)
            ctrl |= AD936X_CTRL_TX_ENABLE;
        /* ctrl is 0 coming from open(); write it explicitly to make the 0→1
         * edge visible in the source and to guard against future callers.
         * The FPGA resets rx_buf_wr to 0 on this edge. */
        writel(0, &priv->regs->ctrl);
        priv->rd_ptr = 0;
        priv->timer_wr_ptr = 0;
        atomic_set(&priv->blocks_ready, 0);
        writel(ctrl, &priv->regs->ctrl);
        return 0;
    }
    default:
        return -ENOTTY;
    }
}

static int ad936x_axi_release(struct inode *inode, struct file *f) {
    struct ad936x_axi *priv = file_to_priv(f);

    priv->closing = true;
    wake_up_all(&priv->tx_wq);
    wake_up_all(&priv->rx_wq);

    hrtimer_cancel(&priv->timer);

    /* Disable FPGA */
    writel(0, &priv->regs->ctrl);

    atomic_set(&priv->in_use, 0);

    return 0;
}

static int ad936x_axi_stats_show(struct seq_file *s, void *unused) {
    struct ad936x_axi *priv = s->private;
    ktime_t now = ktime_get();
    int active = atomic_read(&priv->in_use);

    seq_printf(s, "state:            %s\n", active ? "active" : "idle");

    if (!active) {
        seq_puts(s, "(open the device to see live stats)\n");
        return 0;
    }

    {
        s64 uptime_us = ktime_us_delta(now, priv->open_time);
        u64 total = priv->total_bytes_written;
        u64 samples = total >> 2;
        s64 age_us = ktime_us_delta(now, priv->last_read_time);
        s32 rem;
        u32 urem;
        s64 uptime_s = div_s64_rem(uptime_us, 1000000, &rem);

        seq_printf(s, "uptime:           %lld.%03d s\n", uptime_s, rem / 1000);

        /* Throughput */
        if (uptime_us > 0) {
            u32 uptime_ms = (u32)div_s64(uptime_us, 1000);
            u64 mbps_x100 = div_u64(total * 800ULL, uptime_ms);
            u64 msps_x100 = div_u64(samples * 100000ULL, uptime_ms);

            seq_printf(s, "bandwidth:        %llu.%02u Mbps\n", div_u64_rem(mbps_x100, 100, &urem),
                       urem);
            seq_printf(s, "sample_rate:      %llu.%02u MSPS\n", div_u64_rem(msps_x100, 100, &urem),
                       urem);
        }
        seq_printf(s, "total_bytes:      %llu\n", total);
        seq_printf(s, "total_samples:    %llu\n", samples);

        /* RX */
        if (priv->rxbuf_size > 0) {
            u32 drops = readl(&priv->regs->rx_overflow);
            u32 wr = readl(&priv->regs->rx_buf_wr);
            u32 rd = priv->rd_ptr;
            u32 used = (wr >= rd) ? (wr - rd) : (priv->rxbuf_size - rd + wr);

            seq_printf(s, "rx (wr rd of):    0x%08x 0x%08x %u\n", wr, rd, drops);
            seq_printf(s, "overrun_bytes:    %llu\n", priv->overrun_bytes);
            seq_printf(s, "rx_buf_size:      %zu\n", priv->rxbuf_size);
            seq_printf(s, "rx_buf_used:      %u (%u%%)\n", used,
                       (unsigned int)(used / (priv->rxbuf_size / 100)));
            seq_printf(s, "rx_buf_used_peak: %u (%u%%)\n", priv->buf_used_peak,
                       (unsigned int)(priv->buf_used_peak / (priv->rxbuf_size / 100)));
            seq_printf(s, "read_count:       %llu\n", priv->read_count);
            {
                s32 age_rem;
                s64 age_s = div_s64_rem(age_us, 1000000, &age_rem);
                seq_printf(s, "last_read_age:    %lld.%03d s\n", age_s, age_rem / 1000);
            }
        }

        /* TX */
        if (priv->txbuf_size > 0) {
            u32 wr = priv->tx_wr_ptr;
            u32 rd = readl(&priv->regs->tx_buf_rd);
            u32 underruns = readl(&priv->regs->tx_underrun);
            u32 used = (wr >= rd) ? (wr - rd) : (priv->txbuf_size - rd + wr);

            seq_printf(s, "tx (wr rd ur):    0x%08x 0x%08x %u\n", wr, rd, underruns);
            seq_printf(s, "tx_buf_size:      %zu\n", priv->txbuf_size);
            seq_printf(s, "tx_buf_used:      %u (%u%%)\n", used,
                       priv->txbuf_size ? (unsigned int)(used / (priv->txbuf_size / 100)) : 0);
        }
    }

    return 0;
}

DEFINE_SHOW_ATTRIBUTE(ad936x_axi_stats);

static const struct file_operations ad936x_axi_fops = {
    .owner = THIS_MODULE,
    .open = ad936x_axi_open,
    .read = ad936x_axi_read,
    .write = ad936x_axi_write,
    .mmap = ad936x_axi_mmap,
    .unlocked_ioctl = ad936x_axi_ioctl,
    .release = ad936x_axi_release,
};

static int ad936x_axi_probe(struct platform_device *pdev) {
    struct device *dev = &pdev->dev;
    struct ad936x_axi *priv;
    struct device_node *mem_np;
    struct resource mem_res;
    u32 info;
    int ret;

    priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
    if (!priv)
        return -ENOMEM;

    priv->dev = dev;

    /* Map AXI register space */
    priv->regs = (struct ad936x_axi_regs __iomem *)devm_platform_ioremap_resource(pdev, 0);
    if (IS_ERR(priv->regs))
        return PTR_ERR(priv->regs);

    /* Verify FPGA is present */
    info = readl(&priv->regs->info);
    if ((info >> 16) != AD936X_INFO_MAGIC) {
        dev_err(dev, "INFO register mismatch: 0x%08x (expected 0xAD93xxxx)\n", info);
        return -ENODEV;
    }
    dev_info(dev, "FPGA INFO: 0x%08x\n", info);

    /* Parse memory-region to get the reserved TX buffer */
    mem_np = of_parse_phandle(dev->of_node, "memory-region", 0);
    if (!mem_np) {
        dev_err(dev, "missing memory-region phandle\n");
        return -EINVAL;
    }

    ret = of_address_to_resource(mem_np, 0, &mem_res);
    of_node_put(mem_np);
    if (ret) {
        dev_err(dev, "failed to parse memory-region resource\n");
        return ret;
    }

    priv->txbuf_phys = mem_res.start;
    priv->txbuf_size_max = resource_size(&mem_res);

    /* Parse memory-region to get the reserved RX buffer */
    mem_np = of_parse_phandle(dev->of_node, "memory-region", 1);
    if (!mem_np) {
        dev_err(dev, "missing memory-region phandle\n");
        return -EINVAL;
    }

    ret = of_address_to_resource(mem_np, 0, &mem_res);
    of_node_put(mem_np);
    if (ret) {
        dev_err(dev, "failed to parse memory-region resource\n");
        return ret;
    }

    priv->rxbuf_phys = mem_res.start;
    priv->rxbuf_size_max = resource_size(&mem_res);

    dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));

    dev_info(dev, "TX buffer: phys=%pa size=0x%zx\n", &priv->txbuf_phys, priv->txbuf_size_max);
    dev_info(dev, "RX buffer: phys=%pa size=0x%zx\n", &priv->rxbuf_phys, priv->rxbuf_size_max);

    atomic_set(&priv->in_use, 0);

    priv->misc.minor = MISC_DYNAMIC_MINOR;
    priv->misc.name = "ad936x-axi";
    priv->misc.fops = &ad936x_axi_fops;
    priv->misc.parent = dev;

    ret = misc_register(&priv->misc);
    if (ret) {
        dev_err(dev, "failed to register misc device\n");
        return ret;
    }

    platform_set_drvdata(pdev, priv);

    priv->debugfs_dir = debugfs_create_dir("ad936x-axi", NULL);
    debugfs_create_file("stats", 0444, priv->debugfs_dir, priv, &ad936x_axi_stats_fops);

    dev_info(dev, "registered /dev/ad936x-axi\n");
    return 0;
}

static int ad936x_axi_remove(struct platform_device *pdev) {
    struct ad936x_axi *priv = platform_get_drvdata(pdev);

    debugfs_remove_recursive(priv->debugfs_dir);
    misc_deregister(&priv->misc);

    return 0;
}

static const struct of_device_id ad936x_axi_of_match[] = {{.compatible = "custom,ad936x-axi"}, {}};
MODULE_DEVICE_TABLE(of, ad936x_axi_of_match);

static struct platform_driver ad936x_axi_driver = {
    .probe = ad936x_axi_probe,
    .remove = ad936x_axi_remove,
    .driver =
        {
            .name = "ad936x-axi",
            .of_match_table = ad936x_axi_of_match,
        },
};
module_platform_driver(ad936x_axi_driver);

MODULE_DESCRIPTION("AD936x AXI DMA platform driver");
MODULE_LICENSE("GPL");
