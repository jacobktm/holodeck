mod pty { include!("../pty.rs"); }

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: ptytest <cmd> [args...]");
        std::process::exit(2);
    }
    let refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    match pty::spawn_pty(&refs) {
        Ok(code) => {
            println!("exit status: {code}");
            std::process::exit(code);
        }
        Err(e) => {
            eprintln!("spawn_pty error: {e}");
            std::process::exit(1);
        }
    }
}
