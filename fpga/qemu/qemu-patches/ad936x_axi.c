/*
 * AD936x AXI – thin QEMU shim that delegates to a Rust shared library.
 *
 * All peripheral logic lives in the Rust cdylib loaded at realize time.
 * This file only does QEMU plumbing: device registration, MMIO region,
 * virtual timer, and a DMA-write callback that the Rust side can call.
 *
 * Set AD936X_LIB env var to the path of the .so before launching QEMU.
 *
 * SPDX-License-Identifier: MIT
 */

#include "qemu/osdep.h"
#include "hw/sysbus.h"
#include "qapi/error.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "exec/address-spaces.h"

#include <dlfcn.h>

#define TYPE_AD936X_AXI "custom.ad936x-axi"
OBJECT_DECLARE_SIMPLE_TYPE(AD936xAXIState, AD936X_AXI)

/* Timer interval in nanoseconds (1 ms) */
#define TICK_NS  1000000

/* ---------- function-pointer types matching the Rust exports ---------- */

typedef void *(*fn_create_t)(void);
typedef void  (*fn_destroy_t)(void *ctx);
typedef uint64_t (*fn_read_t)(void *ctx, uint64_t addr, unsigned size);
typedef void  (*fn_write_t)(void *ctx, uint64_t addr, uint64_t val,
                            unsigned size);
typedef void  (*fn_tick_t)(void *ctx,
                           void (*dma_write)(void *opaque, uint64_t addr,
                                            const void *buf, uint32_t len),
                           void *dma_opaque);

/* ----------------------------- state ---------------------------------- */

struct AD936xAXIState {
    SysBusDevice parent_obj;
    MemoryRegion iomem;
    QEMUTimer   *rx_timer;

    /* Rust library */
    void         *lib_handle;
    void         *rust_ctx;
    fn_create_t   fn_create;
    fn_destroy_t  fn_destroy;
    fn_read_t     fn_read;
    fn_write_t    fn_write;
    fn_tick_t     fn_tick;
};

/* --------- DMA-write callback passed to the Rust tick function -------- */

static void dma_write_cb(void *opaque, uint64_t addr,
                         const void *buf, uint32_t len)
{
    (void)opaque;
    address_space_write(&address_space_memory, addr,
                        MEMTXATTRS_UNSPECIFIED, buf, len);
}

/* ----------------------- register access ------------------------------ */

static uint64_t ad936x_axi_read(void *opaque, hwaddr addr, unsigned size)
{
    AD936xAXIState *s = opaque;
    return s->fn_read(s->rust_ctx, addr, size);
}

static void ad936x_axi_write(void *opaque, hwaddr addr, uint64_t val,
                              unsigned size)
{
    AD936xAXIState *s = opaque;
    s->fn_write(s->rust_ctx, addr, val, size);
}

static const MemoryRegionOps ad936x_axi_ops = {
    .read  = ad936x_axi_read,
    .write = ad936x_axi_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

/* ---------------------- timer callback -------------------------------- */

static void ad936x_rx_tick(void *opaque)
{
    AD936xAXIState *s = opaque;

    s->fn_tick(s->rust_ctx, dma_write_cb, NULL);

    timer_mod(s->rx_timer,
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + TICK_NS);
}

/* ---------------------- device lifecycle ------------------------------ */

static void ad936x_axi_init(Object *obj)
{
    AD936xAXIState *s = AD936X_AXI(obj);

    memory_region_init_io(&s->iomem, obj, &ad936x_axi_ops, s,
                          "custom.ad936x-axi", 0x10000);
    sysbus_init_mmio(SYS_BUS_DEVICE(obj), &s->iomem);
}

/* helper: resolve one symbol or set errp and return false */
static bool resolve(void *handle, const char *name, void **out, Error **errp)
{
    *out = dlsym(handle, name);
    if (!*out) {
        error_setg(errp, "ad936x_axi: symbol '%s' not found: %s",
                   name, dlerror());
        return false;
    }
    return true;
}

static void ad936x_axi_realize(DeviceState *dev, Error **errp)
{
    AD936xAXIState *s = AD936X_AXI(dev);
    const char *lib_path;

    lib_path = getenv("AD936X_LIB");
    if (!lib_path) {
        error_setg(errp,
                   "ad936x_axi: AD936X_LIB env var not set");
        return;
    }

    s->lib_handle = dlopen(lib_path, RTLD_NOW);
    if (!s->lib_handle) {
        error_setg(errp,
                   "ad936x_axi: failed to load '%s': %s",
                   lib_path, dlerror());
        return;
    }

    if (!resolve(s->lib_handle, "ad936x_create",  (void **)&s->fn_create,  errp) ||
        !resolve(s->lib_handle, "ad936x_destroy", (void **)&s->fn_destroy, errp) ||
        !resolve(s->lib_handle, "ad936x_read",    (void **)&s->fn_read,    errp) ||
        !resolve(s->lib_handle, "ad936x_write",   (void **)&s->fn_write,   errp) ||
        !resolve(s->lib_handle, "ad936x_tick",     (void **)&s->fn_tick,    errp)) {
        dlclose(s->lib_handle);
        s->lib_handle = NULL;
        return;
    }

    s->rust_ctx = s->fn_create();

    s->rx_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, ad936x_rx_tick, s);
    timer_mod(s->rx_timer,
              qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) + TICK_NS);
}

static void ad936x_axi_finalize(Object *obj)
{
    AD936xAXIState *s = AD936X_AXI(obj);

    if (s->rx_timer) {
        timer_free(s->rx_timer);
    }
    if (s->rust_ctx && s->fn_destroy) {
        s->fn_destroy(s->rust_ctx);
    }
    if (s->lib_handle) {
        dlclose(s->lib_handle);
    }
}

static void ad936x_axi_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    dc->desc    = "AD936x AXI – Rust peripheral shim";
    dc->realize = ad936x_axi_realize;
}

static const TypeInfo ad936x_axi_info = {
    .name            = TYPE_AD936X_AXI,
    .parent          = TYPE_SYS_BUS_DEVICE,
    .instance_size   = sizeof(AD936xAXIState),
    .instance_init   = ad936x_axi_init,
    .instance_finalize = ad936x_axi_finalize,
    .class_init      = ad936x_axi_class_init,
};

static void ad936x_axi_register_types(void)
{
    type_register_static(&ad936x_axi_info);
}

type_init(ad936x_axi_register_types)
