use std::{
    io::Read,
    net::TcpStream,
    sync::mpsc,
    time::{Duration, Instant},
};

fn main() {
    println!("AD936x PRBS checker");

    let (freebuf_wr, freebuf_rd) = mpsc::channel();
    let (usedbuf_wr, usedbuf_rd) = mpsc::channel();

    for _ in 0..16 {
        freebuf_wr.send(vec![0u8; 65536]).unwrap();
    }

    let mut stream = TcpStream::connect("192.168.133.134:1234").expect("Unable to connect");

    let receiver = std::thread::spawn(move || {
        loop {
            let mut buf = freebuf_rd.recv().unwrap();
            stream.read_exact(buf.as_mut_slice()).unwrap();
            usedbuf_wr.send(buf).unwrap();
        }
    });

    let verifier = std::thread::spawn(move || {
        let mut seed = 0;
        let mut errors = 0;
        let mut samples = 0;
        let mut t0 = Instant::now();
        loop {
            let buf = usedbuf_rd.recv().unwrap();
            if seed == 0 {
                let i = u16::from_le_bytes([buf[0], buf[1]]) >> 4;
                let q = u16::from_le_bytes([buf[2], buf[3]]) >> 4;
                seed = state_from_iq(i, q);
            }
            for bytes in buf.chunks_exact(4) {
                let i = u16::from_le_bytes([bytes[0], bytes[1]]) >> 4;
                let q = u16::from_le_bytes([bytes[2], bytes[3]]) >> 4;
                if check(&mut seed, i, q) {
                    if errors == 0 {
                        println!("i={i:03x} q={q:03x} {:b} {:b}", i & 0xff, bitrev12(q) >> 4);
                    }
                    errors += 1;
                }
                samples += 1;
            }
            freebuf_wr.send(buf).unwrap();

            let t1 = Instant::now();
            let td = t1.duration_since(t0);
            if td >= Duration::from_secs(1) {
                t0 = t1;
                let msps = samples as f64 / td.as_secs_f64() / 1e6;
                println!("msps={msps:.3} errors={errors}");
                errors = 0;
                samples = 0;
            }
        }
    });

    receiver.join().unwrap();
    verifier.join().unwrap();
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
