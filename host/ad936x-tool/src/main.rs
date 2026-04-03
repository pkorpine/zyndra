use std::{
    io::{Read, Write},
    net::TcpStream,
    sync::mpsc,
    time::{Duration, Instant},
};

mod iq;
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
    /// CW generator
    Cw {
        /// Amplitude (0.0 - 1.0)
        #[arg(long, default_value_t = 1.0)]
        amplitude: f64,
        /// Normalized frequency (-0.5 - 0.5)
        #[arg(long, default_value_t = 0.0, allow_hyphen_values = true)]
        frequency: f64,
    },
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    let stream = TcpStream::connect_timeout(&args.address.parse()?, Duration::from_secs(1))?;

    match args.mode {
        Operation::PrbsCheck => {
            println!("AD936x PRBS checker");
            recv_prbs_check(stream)
        }
        Operation::Cw {
            amplitude,
            frequency,
        } => {
            println!("CW generator");
            send_cw(stream, amplitude, frequency)
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
