//! AD936x AXI peripheral emulation.
//!
//! This is a cdylib loaded by the QEMU C shim at runtime.
//! All peripheral logic lives here — register map, IQ sample generation,
//! DMA writes into guest RAM via the callback provided by the C side.

// ---------------------------------------------------------------------------
// Register offsets (matching ad936x_axi_pkg.vhd)
// ---------------------------------------------------------------------------

const REG_INFO: u64 = 0x00;
const REG_CTRL: u64 = 0x04;
const REG_TX_UNDERRUN: u64 = 0x08;
const REG_RX_OVERFLOW: u64 = 0x0C;
const REG_RX_BUF_BASE: u64 = 0x10;
const REG_RX_BUF_SIZE: u64 = 0x14;
const REG_RX_BUF_WR: u64 = 0x1C;
const REG_TX_BUF_BASE: u64 = 0x20;
const REG_TX_BUF_SIZE: u64 = 0x24;
const REG_TX_BUF_RD: u64 = 0x28;
const REG_TX_BUF_WR: u64 = 0x2C;

// Control register bits (matching ad936x_axi_pkg.vhd)
const CTRL_RESET: u32 = 1 << 0;
const CTRL_RX_ENABLE: u32 = 1 << 1;
const CTRL_TX_ENABLE: u32 = 1 << 2;

/// Samples written per timer tick (1 ms at 30.72 MSPS would be ~30720,
/// but we keep it small for emulation).
const SAMPLES_PER_TICK: u32 = 256;

/// Tone frequency as a fraction of the sample rate.
/// phase_increment = TAU * f_tone / f_sample.
/// With 0.01 rad/sample this gives ~49 kHz at 30.72 MSPS.
const PHASE_INC: f64 = 0.01;

// ---------------------------------------------------------------------------
// Peripheral state
// ---------------------------------------------------------------------------

struct State {
    ctrl: u32,
    rx_overflow: u32,
    tx_underrun: u32,
    rx_buf_base: u32,
    rx_buf_size: u32,
    rx_buf_wr: u32,
    tx_buf_base: u32,
    tx_buf_size: u32,
    tx_buf_rd: u32,
    tx_buf_wr: u32,
    phase: u32,
}

impl State {
    fn new() -> Self {
        Self {
            ctrl: CTRL_RESET,
            rx_overflow: 0,
            tx_underrun: 0,
            rx_buf_base: 0,
            rx_buf_size: 0,
            rx_buf_wr: 0,
            tx_buf_base: 0,
            tx_buf_size: 0,
            tx_buf_rd: 0,
            tx_buf_wr: 0,
            phase: 0,
        }
    }
}

// ---------------------------------------------------------------------------
// IQ packing (same format as the FPGA)
//   bits[31:20] = Q[11:0]
//   bits[19:16] = 0
//   bits[15:4]  = I[11:0]
//   bits[3:0]   = 0
// ---------------------------------------------------------------------------

fn pack_iq(i_val: i16, q_val: i16) -> u32 {
    let i12 = ((i_val as u32) & 0xFFF) << 4;
    let q12 = ((q_val as u32) & 0xFFF) << 20;
    q12 | i12
}

// ---------------------------------------------------------------------------
// Exported C API
// ---------------------------------------------------------------------------

/// DMA write callback signature matching the C side.
type DmaWriteFn =
    unsafe extern "C" fn(opaque: *mut std::ffi::c_void, addr: u64, buf: *const u8, len: u32);

#[no_mangle]
pub extern "C" fn ad936x_create() -> *mut std::ffi::c_void {
    let state = Box::new(State::new());
    Box::into_raw(state) as *mut std::ffi::c_void
}

#[no_mangle]
pub extern "C" fn ad936x_destroy(ctx: *mut std::ffi::c_void) {
    if !ctx.is_null() {
        unsafe {
            drop(Box::from_raw(ctx as *mut State));
        }
    }
}

#[no_mangle]
pub extern "C" fn ad936x_read(ctx: *mut std::ffi::c_void, addr: u64, _size: u32) -> u64 {
    let s = unsafe { &*(ctx as *const State) };
    match addr {
        REG_INFO => 0xAD93_0001,
        REG_CTRL => s.ctrl as u64,
        REG_TX_UNDERRUN => s.tx_underrun as u64,
        REG_RX_OVERFLOW => s.rx_overflow as u64,
        REG_RX_BUF_BASE => s.rx_buf_base as u64,
        REG_RX_BUF_SIZE => s.rx_buf_size as u64,
        REG_RX_BUF_WR => s.rx_buf_wr as u64,
        REG_TX_BUF_BASE => s.tx_buf_base as u64,
        REG_TX_BUF_SIZE => s.tx_buf_size as u64,
        REG_TX_BUF_RD => s.tx_buf_rd as u64,
        REG_TX_BUF_WR => s.tx_buf_wr as u64,
        _ => {
            eprintln!("ad936x_axi: read at unimplemented offset 0x{addr:02x}");
            0xDEAD_BEEF
        }
    }
}

#[no_mangle]
pub extern "C" fn ad936x_write(ctx: *mut std::ffi::c_void, addr: u64, val: u64, _size: u32) {
    let s = unsafe { &mut *(ctx as *mut State) };
    match addr {
        REG_CTRL => {
            s.ctrl = (val as u32) & (CTRL_RESET | CTRL_RX_ENABLE | CTRL_TX_ENABLE);
            if s.ctrl & CTRL_RESET != 0 {
                s.rx_overflow = 0;
                s.tx_underrun = 0;
                s.rx_buf_wr = 0;
                s.rx_buf_base = 0;
                s.rx_buf_size = 0;
                s.tx_buf_base = 0;
                s.tx_buf_size = 0;
                s.tx_buf_wr = 0;
                s.tx_buf_rd = 0;
                s.phase = 0;
            }
        }
        REG_RX_BUF_BASE => s.rx_buf_base = val as u32,
        REG_RX_BUF_SIZE => s.rx_buf_size = val as u32,
        REG_TX_BUF_BASE => s.tx_buf_base = val as u32,
        REG_TX_BUF_SIZE => s.tx_buf_size = val as u32,
        REG_TX_BUF_WR => s.tx_buf_wr = val as u32,
        _ => {
            eprintln!("ad936x_axi: write 0x{val:08x} at unimplemented offset 0x{addr:02x}");
        }
    }
}

#[no_mangle]
pub extern "C" fn ad936x_tick(
    ctx: *mut std::ffi::c_void,
    dma_write: DmaWriteFn,
    dma_opaque: *mut std::ffi::c_void,
) {
    let s = unsafe { &mut *(ctx as *mut State) };

    if s.ctrl & CTRL_RX_ENABLE == 0 || s.ctrl & CTRL_RESET != 0 || s.rx_buf_size == 0 {
        return;
    }

    for _ in 0..SAMPLES_PER_TICK {
        let angle = (s.phase as f64) * PHASE_INC;
        let i_val = (2000.0 * angle.sin()) as i16;
        let q_val = (2000.0 * angle.cos()) as i16;
        let sample = pack_iq(i_val, q_val);
        let bytes = sample.to_le_bytes();

        let addr = (s.rx_buf_base as u64) + (s.rx_buf_wr as u64);
        unsafe {
            dma_write(dma_opaque, addr, bytes.as_ptr(), 4);
        }

        s.rx_buf_wr = (s.rx_buf_wr + 4) % s.rx_buf_size;
        s.phase = s.phase.wrapping_add(1);
    }
}
