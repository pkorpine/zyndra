pub struct Generator {
    state: u16,
}

impl Default for Generator {
    fn default() -> Self {
        // Initial state matches embedded prbs_init().
        Self { state: 1 }
    }
}

impl Generator {
    /// Fill buf with PRBS samples. buf.len() must be a multiple of 4.
    /// Layout per sample: [i_lo, i_hi, q_lo, q_hi] little-endian i16.
    pub fn fill(&mut self, buf: &mut [u8]) {
        for chunk in buf.chunks_exact_mut(4) {
            let i_val = ((self.state >> 4) & 0xFFF) as i16;
            let q_rev = bitrev12(self.state & 0xFFF) as i16;
            let i = i_val << 4;
            let q = q_rev << 4;
            chunk[0..2].copy_from_slice(&i.to_le_bytes());
            chunk[2..4].copy_from_slice(&q.to_le_bytes());
            self.state = lfsr_next(self.state);
        }
    }
}

#[derive(Default)]
pub struct Checker {
    pub errors: usize,
    pub samples: usize,
    seed: u16,
}

impl Checker {
    pub fn verify(&mut self, buf: &[u8]) {
        if self.seed == 0 {
            let i = u16::from_le_bytes([buf[0], buf[1]]) >> 4;
            let q = u16::from_le_bytes([buf[2], buf[3]]) >> 4;
            self.seed = state_from_iq(i, q);
        }
        for bytes in buf.chunks_exact(4) {
            let i = u16::from_le_bytes([bytes[0], bytes[1]]) >> 4;
            let q = u16::from_le_bytes([bytes[2], bytes[3]]) >> 4;
            if check(&mut self.seed, i, q) {
                // if self.errors == 0 {
                //     println!("i={i:03x} q={q:03x} {:b} {:b}", i & 0xff, bitrev12(q) >> 4);
                // }
                self.errors += 1;
            }
            self.samples += 1;
        }
    }
}

fn check(seed: &mut u16, i: u16, q: u16) -> bool {
    let expected_i = (*seed >> 4) & 0xFFF;
    let error = if i & 0xFFF != expected_i {
        *seed = state_from_iq(i, q);
        true
    } else {
        false
    };
    *seed = lfsr_next(*seed);
    error
}

fn bitrev12(x: u16) -> u16 {
    let mut out = 0u16;
    for i in 0..12 {
        out |= ((x >> i) & 1) << (11 - i);
    }
    out
}

fn lfsr_next(state: u16) -> u16 {
    // Polynomial: next = {state[14:0], (^state[15:4]) ^ (^state[2:1])}
    let xor_hi = ((state >> 4) & 0xFFF).count_ones() & 1;
    let xor_lo = ((state >> 1) & 0x3).count_ones() & 1;
    let new_bit = (xor_hi ^ xor_lo) as u16;
    ((state << 1) | new_bit) & 0xFFFF
}

fn state_from_iq(i: u16, q: u16) -> u16 {
    let q_rev = bitrev12(q & 0xFFF);
    ((i & 0xFFF) << 4) | (q_rev & 0xF)
}
