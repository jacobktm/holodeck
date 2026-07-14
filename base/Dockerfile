FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Configure APT to use the local apt-cacher-ng proxy
RUN echo 'Acquire::http::Proxy "http://PROXY_HOST:3142";' > /etc/apt/apt.conf.d/01proxy

# 1. Inject the Pop!_OS GPG key and APT sources directly from the build context
COPY pop-keyring-2017-archive.gpg /etc/apt/trusted.gpg.d/
COPY *.sources /etc/apt/sources.list.d/

# 2. Set APT preferences to prioritize Pop!_OS packages over Ubuntu base
RUN printf "Package: *\nPin: release o=pop-os\nPin-Priority: 1001\n" > /etc/apt/preferences.d/pop-os

# 3. Bootstrap the official Pop!_OS packages
RUN apt-get update
RUN apt-get install -y --allow-downgrades \
    pop-keyring \
    pop-default-settings
RUN apt-get full-upgrade -y --allow-downgrades
RUN rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]
