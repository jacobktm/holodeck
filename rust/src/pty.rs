use std::sync::atomic::{AtomicI32, Ordering};

static SIGWINCH_PIPE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn sigwinch_handler(_: i32) {
    let fd = SIGWINCH_PIPE.load(Ordering::Relaxed);
    if fd >= 0 {
        let byte: u8 = 1;
        unsafe { libc::write(fd, &byte as *const u8 as *const libc::c_void, 1); }
    }
}

pub fn spawn_pty(args: &[&str]) -> Result<i32, String> {
    let master = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY) };
    if master < 0 {
        return Err("posix_openpt failed".to_string());
    }

    if unsafe { libc::grantpt(master) } < 0 {
        unsafe { libc::close(master) };
        return Err("grantpt failed".to_string());
    }

    if unsafe { libc::unlockpt(master) } < 0 {
        unsafe { libc::close(master) };
        return Err("unlockpt failed".to_string());
    }

    let mut slave_buf = [0i8; 1024];
    if unsafe { libc::ptsname_r(master, slave_buf.as_mut_ptr(), slave_buf.len()) } < 0 {
        unsafe { libc::close(master) };
        return Err("ptsname_r failed".to_string());
    }
    let slave_name = unsafe { std::ffi::CStr::from_ptr(slave_buf.as_ptr()) }
        .to_str()
        .map_err(|_| "invalid pts name".to_string())?
        .to_string();

    // Self-pipe for SIGWINCH
    let mut sig_pipe = [-1i32; 2];
    if unsafe { libc::pipe(sig_pipe.as_mut_ptr()) } < 0 {
        unsafe { libc::close(master) };
        return Err("pipe failed".to_string());
    }
    SIGWINCH_PIPE.store(sig_pipe[1], Ordering::Relaxed);

    // Install SIGWINCH handler
    let mut old_sa: libc::sigaction = unsafe { std::mem::zeroed() };
    let mut sa: libc::sigaction = unsafe { std::mem::zeroed() };
    sa.sa_sigaction = sigwinch_handler as usize;
    sa.sa_flags = libc::SA_RESTART;
    unsafe { libc::sigemptyset(&mut sa.sa_mask) };
    let have_sigwinch =
        unsafe { libc::sigaction(libc::SIGWINCH, &sa, &mut old_sa) } == 0;

    let pid = unsafe { libc::fork() };
    if pid < 0 {
        unsafe { libc::close(master) };
        unsafe { libc::close(sig_pipe[0]) };
        unsafe { libc::close(sig_pipe[1]) };
        SIGWINCH_PIPE.store(-1, Ordering::Relaxed);
        unsafe { libc::sigaction(libc::SIGWINCH, &old_sa, std::ptr::null_mut()) };
        return Err("fork failed".to_string());
    }

    if pid == 0 {
        // ── Child ──
        unsafe {
            libc::close(master);
            libc::close(sig_pipe[0]);
            libc::close(sig_pipe[1]);
        }
        SIGWINCH_PIPE.store(-1, Ordering::Relaxed);

        // Create new session and become session leader
        unsafe { libc::setsid() };

        let slave_fd = unsafe {
            libc::open(slave_name.as_ptr() as *const libc::c_char, libc::O_RDWR)
        };
        if slave_fd < 0 {
            std::process::exit(1);
        }

        // Set as controlling terminal
        unsafe { libc::ioctl(slave_fd, libc::TIOCSCTTY, 0) };

        // Redirect stdin/stdout/stderr
        unsafe {
            libc::dup2(slave_fd, libc::STDIN_FILENO);
            libc::dup2(slave_fd, libc::STDOUT_FILENO);
            libc::dup2(slave_fd, libc::STDERR_FILENO);
        }
        if slave_fd > 2 {
            unsafe { libc::close(slave_fd) };
        }

        // Restore default SIGWINCH handling before exec
        if have_sigwinch {
            let mut default_sa: libc::sigaction = unsafe { std::mem::zeroed() };
            default_sa.sa_sigaction = libc::SIG_DFL;
            unsafe { libc::sigaction(libc::SIGWINCH, &default_sa, std::ptr::null_mut()) };
        }

        // Build argv for execvp
        let c_args: Vec<std::ffi::CString> = args
            .iter()
            .map(|a| std::ffi::CString::new(*a).expect("null byte in arg"))
            .collect();
        let mut ptrs: Vec<*const libc::c_char> =
            c_args.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        unsafe {
            libc::execvp(ptrs[0], ptrs.as_ptr());
        }
        std::process::exit(1);
    }

    // ── Parent ──
    // Keep sig_pipe[1] open — signal handler writes to it.
    // Close the read end of the sig pipe in the relay loop when we're done.

    // Save and set raw mode on stdin
    let mut orig_termios = std::mem::MaybeUninit::<libc::termios>::uninit();
    let is_tty =
        unsafe { libc::tcgetattr(libc::STDIN_FILENO, orig_termios.as_mut_ptr()) } == 0;
    let orig_termios = if is_tty {
        unsafe { orig_termios.assume_init() }
    } else {
        unsafe { std::mem::zeroed() }
    };

    if is_tty {
        let mut raw = orig_termios;
        raw.c_iflag &= !(libc::IGNBRK
            | libc::BRKINT
            | libc::PARMRK
            | libc::ISTRIP
            | libc::INLCR
            | libc::IGNCR
            | libc::ICRNL
            | libc::IXON);
        raw.c_oflag &= !libc::OPOST;
        raw.c_lflag &= !(libc::ECHO | libc::ECHONL | libc::ICANON | libc::ISIG | libc::IEXTEN);
        raw.c_cflag &= !(libc::CSIZE | libc::PARENB);
        raw.c_cflag |= libc::CS8;
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) };
    }

    // Relay loop
    let mut pollfds = [
        libc::pollfd { fd: sig_pipe[0], events: libc::POLLIN, revents: 0 },
        libc::pollfd { fd: master, events: libc::POLLIN, revents: 0 },
        libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 },
    ];

    let mut buf = [0u8; 65536];
    let mut stdin_done = false;

    loop {
        pollfds[0].revents = 0;
        pollfds[1].revents = 0;
        if !stdin_done {
            pollfds[2].revents = 0;
        }

        let nfds = if stdin_done { 2 } else { 3 };
        let ret = unsafe { libc::poll(pollfds.as_mut_ptr(), nfds, -1) };
        if ret < 0 {
            break;
        }

        // SIGWINCH → forward window size to PTY
        if pollfds[0].revents & libc::POLLIN != 0 {
            let _ = unsafe { libc::read(sig_pipe[0], buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
            if unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) } == 0 {
                unsafe { libc::ioctl(master, libc::TIOCSWINSZ, &ws) };
            }
        }

        // PTY master → stdout
        if pollfds[1].revents & libc::POLLIN != 0 {
            loop {
                let n = unsafe {
                    libc::read(master, buf.as_mut_ptr() as *mut libc::c_void, buf.len())
                };
                if n > 0 {
                    unsafe {
                        libc::write(
                            libc::STDOUT_FILENO,
                            buf.as_ptr() as *const libc::c_void,
                            n as usize,
                        );
                    }
                } else {
                    break;
                }
            }
        }
        if pollfds[1].revents & (libc::POLLHUP | libc::POLLERR) != 0 {
            // Child exited — drain remaining output
            loop {
                let n = unsafe {
                    libc::read(master, buf.as_mut_ptr() as *mut libc::c_void, buf.len())
                };
                if n > 0 {
                    unsafe {
                        libc::write(
                            libc::STDOUT_FILENO,
                            buf.as_ptr() as *const libc::c_void,
                            n as usize,
                        );
                    }
                } else {
                    break;
                }
            }
            break;
        }

        // stdin → PTY master
        if !stdin_done && (pollfds[2].revents & libc::POLLIN != 0) {
            let n = unsafe {
                libc::read(
                    libc::STDIN_FILENO,
                    buf.as_mut_ptr() as *mut libc::c_void,
                    buf.len(),
                )
            };
            if n > 0 {
                unsafe {
                    libc::write(master, buf.as_ptr() as *const libc::c_void, n as usize);
                }
            } else {
                // stdin EOF — stop polling it, but keep reading from master
                stdin_done = true;
            }
        }
    }

    // Restore terminal
    if is_tty {
        unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &orig_termios) };
    }

    // Restore SIGWINCH handler
    unsafe { libc::sigaction(libc::SIGWINCH, &old_sa, std::ptr::null_mut()) };

    // Close fds
    unsafe {
        libc::close(sig_pipe[0]);
        libc::close(sig_pipe[1]);
        libc::close(master);
    }
    SIGWINCH_PIPE.store(-1, Ordering::Relaxed);

    // Wait for child
    let mut status: i32 = 0;
    unsafe { libc::waitpid(pid, &mut status, 0) };

    if unsafe { libc::WIFEXITED(status) } {
        Ok(unsafe { libc::WEXITSTATUS(status) })
    } else if unsafe { libc::WIFSIGNALED(status) } {
        Err(format!("killed by signal {}", unsafe { libc::WTERMSIG(status) }))
    } else {
        Err("child exited abnormally".to_string())
    }
}
