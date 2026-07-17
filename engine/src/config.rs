use std::net::SocketAddr;

pub struct Config {
    pub listen_addr: SocketAddr,
}

impl Config {
    pub fn from_env() -> Self {
        let listen_addr = std::env::var("ABYSSAL_ENGINE_ADDR")
            .unwrap_or_else(|_| "127.0.0.1:50052".to_string())
            .parse()
            .expect("ABYSSAL_ENGINE_ADDR must be a valid host:port");

        Config { listen_addr }
    }
}
