use std::{
    io::{Read, Write},
    net::TcpStream,
    sync::mpsc,
    time::{Duration, Instant},
};

mod iq;
mod latency;
mod prbs;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(about = "AD936x PRBS checker")]
struct Args {
    /// Target address (ip:port)
    #[arg(short, long, default_value = "192.168.133.134:1234")]
    address: String,
    /// Operation mode
    #[command(subcommand)]
    mode: Operation,
}

#[derive(Subcommand)]
enum Operation {
    /// Check RX PRBS
    PrbsCheck,
    /// Generate PRBS, transmit to target TX
    PrbsGen,
    /// CW generator
    Cw {
        /// Amplitude (0.0 - 1.0)
        #[arg(long, default_value_t = 1.0)]
        amplitude: f64,
        /// Normalized frequency (-0.5 - 0.5)
        #[arg(long, default_value_t = 0.0, allow_hyphen_values = true)]
        frequency: f64,
    },
    /// Latency loopback test using LFM chirp (radar-style matched filter)
    LatencyTest {
        /// TX address (ip:port) — connect to ad9361-txrx --tx-tcp PORT
        #[arg(long, default_value = "192.168.133.134:1235")]
        tx_address: String,
        /// RX address (ip:port) — connect to ad9361-txrx --rx-tcp PORT
        #[arg(long, default_value = "192.168.133.134:1234")]
        rx_address: String,
        /// Chirp pulse length in samples
        #[arg(long, default_value_t = 256)]
        pulse_len: usize,
        /// Pulse repetition interval in samples (must exceed expected delay)
        #[arg(long, default_value_t = 8192)]
        pri: usize,
        /// Pulse amplitude (0.0 - 1.0)
        #[arg(long, default_value_t = 0.9)]
        amplitude: f64,
        /// Number of independent measurements
        #[arg(long, default_value_t = 20)]
        n: usize,
    },
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    match args.mode {
        Operation::PrbsCheck => {
            let stream =
                TcpStream::connect_timeout(&args.address.parse()?, Duration::from_secs(1))?;
            println!("AD936x PRBS checker");
            recv_prbs_check(stream)
        }
        Operation::PrbsGen => {
            let stream =
                TcpStream::connect_timeout(&args.address.parse()?, Duration::from_secs(1))?;
            println!("PRBS generator");
            send_prbs_gen(stream)
        }
        Operation::Cw {
            amplitude,
            frequency,
        } => {
            let stream =
                TcpStream::connect_timeout(&args.address.parse()?, Duration::from_secs(1))?;
            println!("CW generator");
            send_cw(stream, amplitude, frequency)
        }
        Operation::LatencyTest {
            tx_address,
            rx_address,
            pulse_len,
            pri,
            amplitude,
            n,
        } => {
            println!("Latency loopback test");
            run_latency_test(&tx_address, &rx_address, pulse_len, pri, amplitude, n)
        }
    }
}

fn recv_prbs_check(mut stream: TcpStream) -> anyhow::Result<()> {
    let (freebuf_wr, freebuf_rd) = mpsc::channel();
    let (usedbuf_wr, usedbuf_rd) = mpsc::channel();

    for _ in 0..16 {
        freebuf_wr.send(vec![0u8; 65536]).unwrap();
    }

    let receiver = std::thread::spawn(move || -> anyhow::Result<()> {
        loop {
            let mut buf = freebuf_rd.recv()?;
            stream.read_exact(buf.as_mut_slice())?;
            usedbuf_wr.send(buf)?;
        }
    });

    let verifier = std::thread::spawn(move || -> anyhow::Result<()> {
        let mut t0 = Instant::now();
        let mut checker = prbs::Checker::default();
        loop {
            let buf = usedbuf_rd.recv()?;
            checker.verify(&buf);
            freebuf_wr.send(buf)?;

            let t1 = Instant::now();
            let td = t1.duration_since(t0);
            if td >= Duration::from_secs(1) {
                t0 = t1;
                let msps = checker.samples as f64 / td.as_secs_f64() / 1e6;
                println!("msps={msps:.3} errors={}", checker.errors);
                checker.errors = 0;
                checker.samples = 0;
            }
        }
    });

    let _ = receiver.join();
    let _ = verifier.join();
    Ok(())
}

fn send_prbs_gen(mut stream: TcpStream) -> anyhow::Result<()> {
    let (freebuf_wr, freebuf_rd) = mpsc::channel();
    let (usedbuf_wr, usedbuf_rd) = mpsc::channel();

    for _ in 0..16 {
        freebuf_wr.send(vec![0u8; 65536]).unwrap();
    }

    let generator = std::thread::spawn(move || -> anyhow::Result<()> {
        let mut g = prbs::Generator::default();
        loop {
            let mut buf = freebuf_rd.recv()?;
            g.fill(&mut buf);
            usedbuf_wr.send(buf)?;
        }
    });

    let transmitter = std::thread::spawn(move || -> anyhow::Result<()> {
        let mut t0 = Instant::now();
        let mut samples = 0;
        loop {
            let buf = usedbuf_rd.recv()?;
            stream.write_all(&buf)?;
            samples += buf.len() / 4;
            freebuf_wr.send(buf)?;

            let t1 = Instant::now();
            let td = t1.duration_since(t0);
            if td >= Duration::from_secs(1) {
                t0 = t1;
                let msps = samples as f64 / td.as_secs_f64() / 1e6;
                println!("msps={msps:.3}");
                samples = 0;
            }
        }
    });

    let _ = generator.join();
    let _ = transmitter.join();
    Ok(())
}

fn run_latency_test(
    tx_addr: &str,
    rx_addr: &str,
    pulse_len: usize,
    pri: usize,
    amplitude: f64,
    n_measurements: usize,
) -> anyhow::Result<()> {
    use latency::{Chirp, argmax, psr_db, xcorr_mag2};

    println!(
        "Chirp: {} samples, PRI: {} samples, time-bandwidth product: {}",
        pulse_len, pri, pulse_len
    );
    println!("TX -> {tx_addr}  |  RX <- {rx_addr}");

    let chirp = Chirp::new(pulse_len, pri);
    let template_i = chirp.template_i.clone();
    let template_q = chirp.template_q.clone();

    let tx_stream = TcpStream::connect_timeout(&tx_addr.parse()?, Duration::from_secs(2))?;
    let mut rx_stream = TcpStream::connect_timeout(&rx_addr.parse()?, Duration::from_secs(2))?;

    // TX thread: stream chirp frames continuously
    let frame = {
        let mut f = vec![0u8; pri * 4];
        chirp.fill_frame(&mut f, amplitude);
        f
    };

    let block_samples = 8 * pri;
    let mut delays = Vec::with_capacity(n_measurements);
    let mut psrs = Vec::with_capacity(n_measurements);

    // Receive queue
    let (freebuf_wr, freebuf_rd) = mpsc::channel();
    let (usedbuf_wr, usedbuf_rd) = mpsc::channel();

    for _ in 0..16 {
        freebuf_wr.send(vec![0u8; block_samples * 4]).unwrap();
    }

    let receiver = std::thread::spawn(move || -> anyhow::Result<()> {
        loop {
            let mut buf = freebuf_rd.recv()?;
            rx_stream.read_exact(buf.as_mut_slice())?;
            usedbuf_wr.send(buf)?;
        }
    });

    let _tx = std::thread::spawn(move || -> anyhow::Result<()> {
        let mut s = tx_stream;
        loop {
            s.write_all(&frame)?;
        }
    });

    let verifier = std::thread::spawn(move || -> anyhow::Result<()> {
        for i in 0..n_measurements {
            let buf = usedbuf_rd.recv()?;

            let scale = 1.0 / i16::MAX as f32;
            let (rx_i, rx_q): (Vec<f32>, Vec<f32>) = buf
                .chunks_exact(4)
                .map(|b| {
                    let iv = i16::from_le_bytes([b[0], b[1]]) as f32 * scale;
                    let qv = i16::from_le_bytes([b[2], b[3]]) as f32 * scale;
                    (iv, qv)
                })
                .unzip();
            freebuf_wr.send(buf)?;

            let corr = xcorr_mag2(&rx_i, &rx_q, &template_i, &template_q);
            let peak = argmax(&corr);
            // All peaks land at D + k·PRI; mod recovers D without TX/RX sync
            let delay = peak % pri;
            let psr = psr_db(&corr, peak, pulse_len * 2, pri);

            println!(
                "  #{:03}: delay = {:6} samples,  PSR = {:.1} dB",
                i + 1,
                delay,
                psr
            );

            delays.push(delay as f64);
            psrs.push(psr);
        }

        let n = delays.len() as f64;
        let mean = delays.iter().sum::<f64>() / n;
        let std = (delays.iter().map(|d| (d - mean).powi(2)).sum::<f64>() / n).sqrt();
        let mean_psr = psrs.iter().sum::<f32>() / n as f32;

        println!("\nResults ({n_measurements} measurements):");
        println!("  Delay : {mean:.1} ± {std:.1} samples");
        println!("  PSR   : {mean_psr:.1} dB");
        Ok(())
    });

    let _ = receiver.join();
    let _ = verifier.join();

    Ok(())
}

fn send_cw(mut stream: TcpStream, amplitude: f64, frequency: f64) -> anyhow::Result<()> {
    use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
    use crossterm::terminal;

    let (freebuf_wr, freebuf_rd) = mpsc::channel();
    let (usedbuf_wr, usedbuf_rd) = mpsc::channel();
    let (freq_tx, freq_rx) = mpsc::channel();

    for _ in 0..16 {
        freebuf_wr.send(vec![0u8; 65536]).unwrap();
    }

    let mut cw = iq::CwGen::new(frequency, amplitude);

    let generator = std::thread::spawn(move || -> anyhow::Result<()> {
        loop {
            if let Ok(new_freq) = freq_rx.try_recv() {
                cw.set_frequency(new_freq);
            }
            let mut buf = freebuf_rd.recv()?;
            for chunk in buf.chunks_exact_mut(4) {
                let iq = cw.next_sample();
                let i = (iq.i * i16::MAX as f64) as i16;
                let q = (iq.q * i16::MAX as f64) as i16;
                chunk[0..2].copy_from_slice(&i.to_le_bytes());
                chunk[2..4].copy_from_slice(&q.to_le_bytes());
            }
            usedbuf_wr.send(buf)?;
        }
    });

    let transmitter = std::thread::spawn(move || -> anyhow::Result<()> {
        let mut t0 = Instant::now();
        let mut samples = 0;
        loop {
            let buf = usedbuf_rd.recv()?;
            stream.write_all(&buf)?;
            samples += buf.len() / 4;
            freebuf_wr.send(buf)?;

            let t1 = Instant::now();
            let td = t1.duration_since(t0);
            if td >= Duration::from_secs(1) {
                t0 = t1;
                let msps = samples as f64 / td.as_secs_f64() / 1e6;
                print!("msps={msps:.3}\r\n");
                samples = 0;
            }
        }
    });

    terminal::enable_raw_mode()?;
    let mut frequency = frequency;
    print!("Up/Down to adjust frequency, Ctrl-C/q to quit\r\n");
    print!("frequency={frequency:.4}\r\n");
    loop {
        if !event::poll(Duration::from_millis(100))? {
            continue;
        }
        if let Event::Key(KeyEvent {
            code, modifiers, ..
        }) = event::read()?
        {
            match (code, modifiers) {
                (KeyCode::Up, _) => frequency = (frequency + 0.01).min(0.5),
                (KeyCode::Down, _) => frequency = (frequency - 0.01).max(-0.5),
                (KeyCode::Char('q'), _) => break,
                (KeyCode::Char('c'), m) if m.contains(KeyModifiers::CONTROL) => break,
                _ => continue,
            }
            // drain queued key repeats
            while event::poll(Duration::ZERO)? {
                let _ = event::read();
            }
            print!("frequency={frequency:.4}\r\n");
            let _ = freq_tx.send(frequency);
        }
    }
    terminal::disable_raw_mode()?;

    let _ = generator.join();
    let _ = transmitter.join();
    Ok(())
}
