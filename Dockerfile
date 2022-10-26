# FROM ubuntu:jammy AS sonic
FROM debian:bookworm AS sonic
ENV DEBIAN_FRONTEND=noninteractive
ENV CURL_V 7.83.1
RUN apt update; \
    apt install -y  curl clang libclang-dev build-essential; \
    # wget -q -O /usr/local/bin/curl https://github.com/moparisthebest/static-curl/releases/download/v$CURL_V/curl-amd64 && \
    # chmod +x /usr/local/bin/curl && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -q --profile minimal --default-toolchain stable -y && \
    /root/.cargo/bin/cargo install sonic-server && \
    cp /root/.cargo/bin/sonic /usr/local/bin && \
    /root/.cargo/bin/rustup self uninstall -y && \
    apt remove libclang-dev; \
    apt autoremove -y
# debug tools
RUN apt install -y python3-dbg gdb vim procps auditd

FROM sonic AS gost
ENV GOST_V=2.11.2
RUN curl -L https://github.com/ginuerzh/gost/releases/download/v${GOST_V}/gost-linux-amd64-${GOST_V}.gz -o gost.gz; \
    gzip -d gost.gz ; \
    chmod +x gost; \
    mv gost /usr/local/bin;

FROM gost AS nimrt
RUN apt -y install git lld file
# This should install nim version 1.6.x
RUN curl https://nim-lang.org/choosenim/init.sh -sSf | sh -s -- -y
RUN echo PATH=/root/.nimble/bin:\$PATH >> /root/.profile
RUN ln -sr /root/.choosenim/toolchains/*/tools /root/.nimble
RUN bash -c "$(curl -fsSL https://gef.blah.cat/sh)"
# required by gef
RUN apt update -y; apt -y install locales; \
    sed '/en_US.UTF-8/s/^# //g' -i /etc/locale.gen && \
    locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8
SHELL ["/bin/bash", "-lc"]

# FROM nimrt as pyenv
# RUN curl https://pyenv.run | bash
# RUN echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.profile
# RUN echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.profile
# RUN echo 'eval "$(pyenv init -)"' >> ~/.profile


FROM nimrt AS siteenv
ENV PROJECT_DIR=/site
ENV DOCKER 1
RUN mkdir /site
COPY /site.nimble /site/
WORKDIR /site
VOLUME ["/site/data"]

FROM siteenv AS sitedeps1
# install nimterop separately
ARG CLEARCACHE=4
RUN curl http://ftp.de.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1n-0+deb11u3_amd64.deb --output libssl.deb && \
    dpkg -i libssl.deb && \
    rm libssl.deb
RUN cd /; nimble install -y nimterop
RUN cd /
RUN cd /site; \
    tries=3; \
    while true; do \
        nimble install -y -d --verbose && break; \
        tries=$((tries+1)); \
        [ $tries -gt 3 ] && exit 1; \
    done


FROM sitedeps1 AS sitedeps2
ARG CACHE 0
RUN apt update -y ; \
    apt install -y python3-dev python3-pip git libcurl4-openssl-dev libssl-dev gcc; true
RUN /usr/bin/pip3 install wheel requests pyyaml supervisor bs4 six
COPY /requirements.git.txt /site/
RUN /usr/bin/pip3 install -r requirements.git.txt
COPY /requirements.txt /site/
RUN /usr/bin/pip3 install -r requirements.txt
# split requirements that cause dep conflicts
COPY /requirements2.txt /site/
RUN /usr/bin/pip3 install -r requirements2.txt
# this has to be installed at the end for `lassie` compatibility
RUN /usr/bin/pip3 install --upgrade --pre html5lib

FROM sitedeps2 AS sitedeps3
RUN /usr/bin/python3 -m textblob.download_corpora
RUN /usr/bin/python3 lib/py/main.py; true # perform modules setups on imports

FROM sitedeps3 as scraper
ENV SITES wsl,wsl
COPY / /site/
CMD /site/scripts/scraper.sh

FROM scraper AS site
ENV NIM_DEBUG debug
ARG NIM_ARG release
ENV NIM $NIM_ARG
ARG LIBPYTHON_PATH /usr/lib/x86_64-linux-gnu/libpython3.10d.so
# nim not still supporting ssl3
# RUN apt -y install libssl1.1
RUN /site/scripts/switchdebug.sh /site
CMD ./cli

# FROM siteBase as site
# RUN apt update -y; apt install -y autotools-dev automake
# RUN cd /tmp && \
#     git clone --depth=1 git://sourceware.org/git/valgrind.git && \
#     cd valgrind && \
#     ./autogen.sh && \
#     ./configure && \
#     make -j $(nproc) && \
#     make install && \
#     cd - && \
#     rm /tmp/valgrind -rf
# RUN apt -y install massif-visualizer

FROM site AS wsl
ENV CONFIG_NAME wsl
ENV SITE_PORT 5050
HEALTHCHECK --timeout=5s CMD scripts/healthcheck.sh
RUN cd /site; nimble build cli
RUN [ "$NIM" = release ] && strip -s cli || exit 0

FROM site as wsl
ENV CONFIG_NAME wsl
ENV SITE_PORT 5051
ENV NEW_TOPICS_ENABLED True
HEALTHCHECK --timeout=5s CMD scripts/healthcheck.sh
RUN cd /site; nimble build cli
RUN [ "$NIM" = release ] && strip -s cli || exit 0
