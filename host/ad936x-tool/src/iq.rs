use std::f64::consts::TAU;

pub struct Iq {
    pub i: f64,
    pub q: f64,
}

pub struct CwGen {
    phase: f64,
    phase_inc: f64,
    amplitude: f64,
}

impl CwGen {
    /// `norm_freq`: normalized frequency in (-0.5, 0.5), where 1.0 = fs
    pub fn new(norm_freq: f64, amplitude: f64) -> Self {
        Self {
            phase: 0.,
            phase_inc: TAU * norm_freq,
            amplitude,
        }
    }

    pub fn set_frequency(&mut self, norm_freq: f64) {
        self.phase_inc = TAU * norm_freq;
    }

    pub fn next_sample(&mut self) -> Iq {
        let iq = Iq {
            i: self.phase.cos() * self.amplitude,
            q: self.phase.sin() * self.amplitude,
        };
        self.phase += self.phase_inc;
        if self.phase >= TAU {
            self.phase -= TAU;
        }
        iq
    }
}

impl Iterator for CwGen {
    type Item = Iq;

    fn next(&mut self) -> Option<Self::Item> {
        Some(self.next_sample())
    }
}
