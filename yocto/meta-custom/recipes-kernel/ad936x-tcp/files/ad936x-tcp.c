// SPDX-License-Identifier: GPL-2.0-only
/*
 * ad936x-tcp - Kernel-side TCP streaming for AD936x AXI DMA data.
 *
 * Listens on a TCP port, accepts a connection, and streams RX IQ data
 * directly from the DMA ring buffer using kernel sockets — no userspace
 * copy path.
 */

#include <linux/cpu.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/kthread.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/platform_device.h>
#include <linux/uio.h>

#include <linux/in.h>
#include <linux/net.h>
#include <net/sock.h>
#include <net/tcp.h>

/* Register layout — must match FPGA RTL (ad936x_axi.vhd) */
struct ad936x_axi_regs {
    u32 info;        /* 0x00  read-only, upper 16 bits = 0xAD93 */
    u32 fifo;        /* 0x04  legacy FIFO readout */
    u32 ctrl;        /* 0x08  bit 0 = enable, bit 1 = reset */
    u32 drop_cnt;    /* 0x0C  dropped sample counter */
    u32 rx_buf_base; /* 0x10  DMA base physical address */
    u32 rx_buf_size; /* 0x14  DMA buffer size in bytes */
    u32 _reserved;   /* 0x18 */
    u32 rx_buf_wr;   /* 0x1C  FPGA write pointer (byte offset from base) */
};

#define AD936X_CTRL_ENABLE BIT(0)
#define AD936X_CTRL_RESET BIT(1)
#define AD936X_INFO_MAGIC 0xAD93

#define TCP_PORT 1234

static unsigned int block_size = 65536;
module_param(block_size, uint, 0444);
MODULE_PARM_DESC(block_size, "TCP send block size in bytes (default 65536)");

struct ad936x_tcp {
    struct device *dev;
    struct ad936x_axi_regs __iomem *regs;
    phys_addr_t rxbuf_phys;
    void *rxbuf_virt;
    size_t rxbuf_size;
    u32 rd_ptr;

    struct task_struct *listen_thread;
};

static void fpga_reset_and_enable(struct ad936x_tcp *priv) {
    writel(AD936X_CTRL_RESET, &priv->regs->ctrl);
    writel(0, &priv->regs->ctrl);
    writel(priv->rxbuf_phys, &priv->regs->rx_buf_base);
    writel(priv->rxbuf_size, &priv->regs->rx_buf_size);
    writel(AD936X_CTRL_ENABLE, &priv->regs->ctrl);
    priv->rd_ptr = 0;
}

static void fpga_disable(struct ad936x_tcp *priv) { writel(0, &priv->regs->ctrl); }

/*
 * Send `len` bytes from virtual address `data` through the kernel socket.
 * Returns 0 on success, negative on error.
 */
static int ksock_send(struct socket *sock, void *data, size_t len) {
    while (len > 0) {
        struct kvec vec = {
            .iov_base = data,
            .iov_len = len,
        };
        struct msghdr msg = {};
        int sent;

        sent = kernel_sendmsg(sock, &msg, &vec, 1, len);
        if (sent < 0)
            return sent;
        if (sent == 0)
            return -ECONNRESET;

        data += sent;
        len -= sent;
    }
    return 0;
}

#define MAX_BVEC_PAGES 256 /* 1 MB / 4 KB */

static int ksock_sendpage(struct socket *sock, void *data, size_t len) {
    struct bio_vec bvec[MAX_BVEC_PAGES];
    struct msghdr msg = {};
    size_t remaining = len;
    int i = 0;

    while (remaining > 0 && i < MAX_BVEC_PAGES) {
        struct page *page = virt_to_page(data);
        unsigned int offset = offset_in_page(data);
        size_t chunk = min_t(size_t, remaining, PAGE_SIZE - offset);

        bvec_set_page(&bvec[i++], page, chunk, offset);
        data += chunk;
        remaining -= chunk;
    }

    iov_iter_bvec(&msg.msg_iter, ITER_SOURCE, bvec, i, len);

    while (msg_data_left(&msg)) {
        int sent = sock_sendmsg(sock, &msg);
        if (sent < 0)
            return sent;
        if (sent == 0)
            return -ECONNRESET;
    }
    return 0;
}

/*
 * Stream data from the DMA ring buffer to the connected client.
 * Returns when the connection drops or kthread_should_stop().
 */
static void stream_to_client(struct ad936x_tcp *priv, struct socket *client) {
    struct device *dev = priv->dev;

    fpga_reset_and_enable(priv);
    dev_info(dev, "streaming started\n");

    while (!kthread_should_stop()) {
        u32 wr_ptr, avail;

        wr_ptr = readl(&priv->regs->rx_buf_wr);

        if (wr_ptr >= priv->rd_ptr)
            avail = wr_ptr - priv->rd_ptr;
        else
            avail = priv->rxbuf_size - priv->rd_ptr + wr_ptr;

        if (avail < block_size) {
            usleep_range(200, 300);
            continue;
        }

        /* Invalidate cache for this block */
        dma_sync_single_for_cpu(dev, priv->rxbuf_phys + priv->rd_ptr, block_size, DMA_FROM_DEVICE);

#if 1
        /* Send the block */
        if (ksock_send(client, priv->rxbuf_virt + priv->rd_ptr, block_size) < 0) {
#else
        if (ksock_sendpage(client, priv->rxbuf_virt + priv->rd_ptr, block_size) < 0) {
#endif
            dev_info(dev, "client disconnected\n");
            break;
        }

        /* Advance read pointer */
        priv->rd_ptr += block_size;
        if (priv->rd_ptr >= priv->rxbuf_size)
            priv->rd_ptr = 0;
    }

    fpga_disable(priv);
    dev_info(dev, "streaming stopped\n");
}

static int listen_thread_fn(void *data) {
    struct ad936x_tcp *priv = data;
    struct device *dev = priv->dev;
    struct socket *listen_sock = NULL;
    struct sockaddr_in addr;
    int ret, one = 1;

    ret = sock_create_kern(&init_net, AF_INET, SOCK_STREAM, IPPROTO_TCP, &listen_sock);
    if (ret < 0) {
        dev_err(dev, "sock_create_kern failed: %d\n", ret);
        return ret;
    }

    /* SO_REUSEADDR */
    sock_setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, KERNEL_SOCKPTR(&one), sizeof(one));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(TCP_PORT);

    ret = kernel_bind(listen_sock, (struct sockaddr *)&addr, sizeof(addr));
    if (ret < 0) {
        dev_err(dev, "bind failed: %d\n", ret);
        goto out;
    }

    ret = kernel_listen(listen_sock, 1);
    if (ret < 0) {
        dev_err(dev, "listen failed: %d\n", ret);
        goto out;
    }

    dev_info(dev, "listening on port %d\n", TCP_PORT);

    while (!kthread_should_stop()) {
        struct socket *client = NULL;

        ret = kernel_accept(listen_sock, &client, 0);
        if (ret < 0) {
            if (ret == -EAGAIN || ret == -ERESTARTSYS)
                continue;
            dev_err(dev, "accept failed: %d\n", ret);
            break;
        }

        dev_info(dev, "client connected\n");

        /* Set large send buffer */
        {
            int sndbuf = 8 * 1024 * 1024;
            sock_setsockopt(client, SOL_SOCKET, SO_SNDBUF, KERNEL_SOCKPTR(&sndbuf), sizeof(sndbuf));
        }

        /* TCP_NODELAY */
        tcp_sock_set_nodelay(client->sk);

        stream_to_client(priv, client);

        kernel_sock_shutdown(client, SHUT_RDWR);
        sock_release(client);
    }

out:
    if (listen_sock)
        sock_release(listen_sock);
    return 0;
}

static int ad936x_tcp_probe(struct platform_device *pdev) {
    struct device *dev = &pdev->dev;
    struct ad936x_tcp *priv;
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
        dev_err(dev, "INFO register mismatch: 0x%08x\n", info);
        return -ENODEV;
    }
    dev_info(dev, "FPGA INFO: 0x%08x\n", info);

    /* Parse memory-region for the reserved RX buffer */
    mem_np = of_parse_phandle(dev->of_node, "memory-region", 0);
    if (!mem_np) {
        dev_err(dev, "missing memory-region phandle\n");
        return -EINVAL;
    }

    ret = of_address_to_resource(mem_np, 0, &mem_res);
    of_node_put(mem_np);
    if (ret) {
        dev_err(dev, "failed to parse memory-region\n");
        return ret;
    }

    priv->rxbuf_phys = mem_res.start;
    priv->rxbuf_size = resource_size(&mem_res);

    dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));

    /* No ioremap needed — reserved-memory without no-map is part of the
     * kernel linear map, so phys_to_virt() gives us a cached pointer. */
    priv->rxbuf_virt = phys_to_virt(priv->rxbuf_phys);

    dev_info(dev, "RX buffer: phys=%pa size=0x%zx virt=%p\n", &priv->rxbuf_phys, priv->rxbuf_size,
             priv->rxbuf_virt);

    platform_set_drvdata(pdev, priv);

    /* Start the listener thread */
    // priv->listen_thread = kthread_run(listen_thread_fn, priv, "ad936x-tcp");
    // if (IS_ERR(priv->listen_thread)) {
    //     dev_err(dev, "failed to start listen thread\n");
    //     return PTR_ERR(priv->listen_thread);
    // }
    priv->listen_thread = kthread_create(listen_thread_fn, priv, "ad936x-tcp");
    if (IS_ERR(priv->listen_thread)) {
        dev_err(dev, "failed to create listen thread\n");
        return PTR_ERR(priv->listen_thread);
    }
    kthread_bind(priv->listen_thread, 1);
    wake_up_process(priv->listen_thread);

    return 0;
}

static int ad936x_tcp_remove(struct platform_device *pdev) {
    struct ad936x_tcp *priv = platform_get_drvdata(pdev);

    kthread_stop(priv->listen_thread);
    fpga_disable(priv);

    return 0;
}

static const struct of_device_id ad936x_tcp_of_match[] = {
    {.compatible = "custom,ad936x-axi"},
    {},
};
MODULE_DEVICE_TABLE(of, ad936x_tcp_of_match);

static struct platform_driver ad936x_tcp_driver = {
    .probe = ad936x_tcp_probe,
    .remove = ad936x_tcp_remove,
    .driver =
        {
            .name = "ad936x-tcp",
            .of_match_table = ad936x_tcp_of_match,
        },
};
module_platform_driver(ad936x_tcp_driver);

MODULE_DESCRIPTION("AD936x AXI DMA TCP streaming driver");
MODULE_LICENSE("GPL");
