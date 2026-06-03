use std::f64::consts::TAU;

pub struct Chirp {
    pub pri: usize,
    pub template_i: Vec<f32>,
    pub template_q: Vec<f32>,
}

impl Chirp {
    /// LFM chirp sweeping from -fs/2 to +fs/2 over pulse_len samples.
    /// φ(n) = 2π·n·(-½ + n/(2·T)) gives instantaneous freq f(n) = -½ + n/T.
    pub fn new(pulse_len: usize, pri: usize) -> Self {
        assert!(pulse_len <= pri, "pulse_len must be <= pri");
        let t = pulse_len as f64;
        let (template_i, template_q) = (0..pulse_len)
            .map(|n| {
                let nf = n as f64;
                let phase = TAU * nf * (-0.5 + nf / (2.0 * t));
                (phase.cos() as f32, phase.sin() as f32)
            })
            .unzip();
        Self { pri, template_i, template_q }
    }

    /// Fill buf (pri * 4 bytes) with one TX frame: chirp then zero padding.
    pub fn fill_frame(&self, buf: &mut [u8], amplitude: f64) {
        assert_eq!(buf.len(), self.pri * 4);
        buf.fill(0);
        let scale = amplitude * i16::MAX as f64;
        for (n, (&ti, &tq)) in self.template_i.iter().zip(self.template_q.iter()).enumerate() {
            let off = n * 4;
            let i = (ti as f64 * scale).round() as i16;
            let q = (tq as f64 * scale).round() as i16;
            buf[off..off + 2].copy_from_slice(&i.to_le_bytes());
            buf[off + 2..off + 4].copy_from_slice(&q.to_le_bytes());
        }
    }
}

pub fn xcorr_mag2(rx_i: &[f32], rx_q: &[f32], ti: &[f32], tq: &[f32]) -> Vec<f32> {
    let p = ti.len();
    let n = rx_i.len();
    if n < p {
        return vec![];
    }

    let mut result = Vec::with_capacity(n - p + 1);

    for lag in 0..=(n - p) {
        let mut si = 0f32;
        let mut sq = 0f32;

        for j in 0..p {
            let ri = rx_i[lag + j];
            let rq = rx_q[lag + j];

            si += ti[j] * ri + tq[j] * rq;
            sq += ti[j] * rq - tq[j] * ri;
        }

        result.push(si * si + sq * sq);
    }

    result
}

pub fn argmax(v: &[f32]) -> usize {
    v.iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap())
        .map(|(i, _)| i)
        .unwrap_or(0)
}

/// Peak-to-sidelobe ratio in dB.
/// Sidelobe = max correlation value outside all periodic peaks (±guard at each k·PRI).
/// Guard should be >= pulse_len to exclude the matched-filter main lobe.
pub fn psr_db(corr: &[f32], peak_idx: usize, guard: usize, pri: usize) -> f32 {
    let peak_val = corr[peak_idx];
    let delay = peak_idx % pri;
    let sidelobe = corr
        .iter()
        .enumerate()
        .filter(|&(i, _)| {
            let phase = i % pri;
            let d = phase.abs_diff(delay).min(pri - phase.abs_diff(delay));
            d > guard
        })
        .map(|(_, &v)| v)
        .fold(0f32, f32::max);
    if sidelobe > 0.0 {
        10.0 * (peak_val / sidelobe).log10()
    } else {
        f32::INFINITY
    }
}
