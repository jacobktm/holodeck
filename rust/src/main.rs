mod btrfs;
mod boot;
mod commands;
mod config;
mod mount;
mod pty;
mod transfer;

use std::path::PathBuf;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "immutable", about = "Immutable Pop!_OS management", version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// List all overlays with sizes
    List,
    /// Print overlay names, one per line
    ListNames,
    /// Show system status and boot config
    Status,
    /// Create a new overlay from a source
    Create { name: String, from: Option<String> },
    /// Delete an overlay
    Delete { name: String },
    /// Reset an overlay from its source
    Reset { name: String },
    /// Set the boot overlay
    Switch { name: String },
    /// Make @base read-only
    Lock,
    /// Make @base writable
    Unlock,
    /// Recreate recovery overlay from @base
    ResetRecovery,
    /// Remove stale boot entries from ESP
    CleanBoot,
    /// Regenerate initramfs and sync to ESP
    UpdateInitramfs { args: Vec<String> },
    /// Interactive shell in an overlay
    Shell {
        name: String,
        #[arg(allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Run a command in an overlay
    Run {
        name: String,
        #[arg(allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Ensure all immutable system files are installed and up to date
    Ensure,
    /// Export an overlay as a compressed btrfs send stream
    Export {
        name: String,
        #[arg(short, long, default_value = "sanitized", value_parser = ["sanitized", "minimal", "full"])]
        mode: String,
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Import an exported overlay from a compressed btrfs send stream
    Import {
        file: PathBuf,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        switch: bool,
    },
}

fn main() {
    let cli = Cli::parse();
    let result = match &cli.command {
        Commands::List => commands::cmd_list(),
        Commands::ListNames => commands::cmd_list_names(),
        Commands::Status => commands::cmd_status(),
        Commands::Create { name, from } => commands::cmd_create(name, from.as_deref()),
        Commands::Delete { name } => commands::cmd_delete(name),
        Commands::Reset { name } => commands::cmd_reset(name),
        Commands::Switch { name } => commands::cmd_switch(name),
        Commands::Lock => commands::cmd_lock(),
        Commands::Unlock => commands::cmd_unlock(),
        Commands::ResetRecovery => commands::cmd_reset_recovery(),
        Commands::CleanBoot => commands::cmd_clean_boot(),
        Commands::UpdateInitramfs { args } => commands::cmd_update_initramfs(args),
        Commands::Shell { name, args } => commands::cmd_shell(name, args),
        Commands::Run { name, args } => commands::cmd_run(name, args),
        Commands::Ensure => commands::cmd_ensure(),
        Commands::Export { name, mode, output } => transfer::cmd_export(name, mode, output.as_deref()),
        Commands::Import { file, name, switch } => transfer::cmd_import(file, name.as_deref(), *switch),
    };
    match result {
        Ok(()) => std::process::exit(0),
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    }
}
