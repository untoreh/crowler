FROM ubuntu:focal AS sonic
ENV DEBIAN_FRONTEND=noninteractive
RUN apt update; \
    apt install -y curl libclang-dev build-essential gdb vim; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -q --profile minimal --default-toolchain stable -y && \
    /root/.cargo/bin/cargo install sonic-server && \
    cp /root/.cargo/bin/sonic /usr/local/bin && \
    /root/.cargo/bin/rustup self uninstall -y && \
    apt remove libclang-dev; \
    apt autoremove -y

FROM sonic AS gost
ENV GOST_V=2.11.2
RUN curl -L https://github.com/ginuerzh/gost/releases/download/v${GOST_V}/gost-linux-amd64-${GOST_V}.gz -o gost.gz; \
    gzip -d gost.gz ; \
    chmod +x gost; \
    mv gost /usr/local/bin;

FROM gost AS nimrt
RUN apt -y install git lld
RUN curl https://nim-lang.org/choosenim/init.sh -sSf | sh -s -- -y
RUN echo PATH=/root/.nimble/bin:\$PATH >> /root/.profile
RUN ln -sr /root/.choosenim/toolchains/*/tools /root/.nimble
SHELL ["/bin/bash", "-lc"]

FROM nirmrt as pyenv
RUN curl https://pyenv.run | bash
RUN echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.profile
RUN echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.profile
RUN echo 'eval "$(pyenv init -)"' >> ~/.profile


FROM nimrt AS siteenv
ENV PROJECT_DIR=/site
RUN mkdir /site
COPY /site.nimble /site/
WORKDIR /site
VOLUME ["/site/data"]

FROM siteenv AS sitedeps1
# install nimterop separately
RUN cd /; nimble install -y nimterop -d
RUN cd /
RUN cd /site; \
    while true; do nimble install -y -d --verbose && break; done


FROM sitedeps1 AS sitedeps2
RUN apt update -y ; \
    apt install -y python3-dev python3-pip git libcurl4-openssl-dev libssl-dev gcc; true
COPY /requirements.txt /site/
RUN pip3 install pyyaml supervisor && \
    pip3 install -r requirements.txt

FROM sitedeps2 AS scraper
ENV SITES wsl,wsl
COPY / /site/
RUN python3 -m textblob.download_corpora
RUN python3 lib/py/main.py; true # perform modules setups on imports
CMD /site/scripts/scraper.sh

FROM scraper AS site
ENV NIM_DEBUG debug
ENV NIM release
CMD ./cli

FROM site AS wsl
ENV CONFIG_NAME wsl
ENV SITE_PORT 5050
HEALTHCHECK --timeout=5s CMD timeout 5 curl --fail http://localhost:5050 || exit 1
RUN cd /site; nimble build ; strip -s cli

FROM site as wsl
ENV CONFIG_NAME wsl
ENV SITE_PORT 5051
ENV NEW_TOPICS_ENABLED True
HEALTHCHECK --timeout=5s CMD timeout 5 curl --fail http://localhost:5051 || exit 1
RUN cd /site; nimble build ; strip -s cli
