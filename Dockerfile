# =============================================================================
# haggai_computer — a full XFCE desktop in a container, reached over RustDesk
# (Direct IP Access, sovereign — no relay), pre-loaded with a heavy
# dev / reverse-engineering / data toolchain so OpenAI Codex can do real work.
# The image builds on the powerful host; Haggai only streams pixels.
#
# The toolchain in this file is VENDORED — with its original explanations and
# structure — from BigBIueWhale/vibe_web_terminal/docker/Dockerfile. A provenance
# copy of that upstream file lives at docs/vibe_web_terminal.Dockerfile.reference.
#
# What was deliberately removed (and fully scrubbed, not stubbed):
#   * the Mistral "vibe" CLI and its config/secrets/system-prompt scaffolding
#   * the Qwen Code CLI and its config
#   * the @ai-sdk/mistral provider and the Ollama / air-gap wiring
#   * ttyd's web-serving entrypoint (EXPOSE 7681 / CMD ttyd) — we deliver a real
#     desktop over RustDesk instead. (The ttyd binary itself is still built, as a
#     tool, but is never served.)
#
# Deliberate deviations from upstream (each marked inline below):
#   * Node.js is installed from NodeSource 22.x, NOT Ubuntu's apt `nodejs`
#     (18.x on noble): OpenAI Codex requires Node >= 22.
#   * uv is installed system-wide (/usr/local/bin), because /home/user is a
#     runtime bind-mount that would shadow a per-user install.
#   * the interactive account is `user` (uid 1000), a PASSWORD-REQUIRED sudoer;
#     no password is baked — setup.sh sets it (== the RustDesk password) at deploy.
# =============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm-256color
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# ============================================================
# SYSTEM PACKAGES (consolidated into larger groups)
# ============================================================

# Core utilities, shells, version control, network tools
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    aria2 \
    vim \
    nano \
    emacs-nox \
    htop \
    tree \
    jq \
    yq \
    ripgrep \
    fd-find \
    bat \
    fzf \
    tmux \
    screen \
    zsh \
    sudo \
    openssh-client \
    openssh-server \
    ca-certificates \
    locales \
    man-db \
    less \
    file \
    unzip \
    zip \
    p7zip-full \
    xz-utils \
    bzip2 \
    rsync \
    strace \
    ltrace \
    lsof \
    psmisc \
    sysstat \
    patch \
    diffutils \
    colordiff \
    dos2unix \
    rename \
    pv \
    parallel \
    entr \
    at \
    cron \
    git \
    git-lfs \
    gitk \
    git-gui \
    git-svn \
    git-doc \
    tig \
    subversion \
    mercurial \
    socat \
    netcat-openbsd \
    iputils-ping \
    iputils-arping \
    iputils-tracepath \
    net-tools \
    dnsutils \
    iproute2 \
    traceroute \
    telnet \
    nmap \
    tcpdump \
    iftop \
    nethogs \
    mtr-tiny \
    whois \
    openssl \
    iperf3 \
    httpie \
    apt-transport-https \
    gnupg2 \
    wireguard-tools \
    openvpn \
    sshpass \
    sshfs \
    && rm -rf /var/lib/apt/lists/*

# Build toolchain, compilers, debugging tools, embedded dev
# (clang/clang-format/clang-tidy only — full LLVM/lldb/lld/libc++ dropped to save ~300 MB)
# (kept arm-none-eabi + aarch64; dropped armhf + riscv64 + qemu-system-misc to save ~300 MB)
RUN apt-get update && apt-get install -y \
    build-essential \
    gcc \
    g++ \
    gfortran \
    cmake \
    cmake-curses-gui \
    make \
    automake \
    autoconf \
    libtool \
    pkg-config \
    nasm \
    yasm \
    swig \
    ccache \
    ninja-build \
    meson \
    libboost-dev \
    libboost-filesystem-dev \
    libboost-system-dev \
    libboost-thread-dev \
    libboost-program-options-dev \
    libboost-regex-dev \
    libboost-iostreams-dev \
    libboost-serialization-dev \
    libboost-date-time-dev \
    libboost-test-dev \
    libboost-log-dev \
    libboost-json-dev \
    gdb \
    gdbserver \
    gdb-multiarch \
    valgrind \
    clang \
    clang-format \
    clang-tidy \
    cppcheck \
    iwyu \
    binutils \
    binutils-multiarch \
    elfutils \
    dwarves \
    linux-tools-common \
    gcc-arm-none-eabi \
    gdb-arm-none-eabi \
    libnewlib-arm-none-eabi \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    openocd \
    minicom \
    picocom \
    u-boot-tools \
    device-tree-compiler \
    qemu-user-static \
    qemu-system-arm \
    && rm -rf /var/lib/apt/lists/*

# Buildroot & Yocto dependencies
RUN apt-get update && apt-get install -y \
    bc \
    cpio \
    gawk \
    findutils \
    libncurses-dev \
    libncursesw5-dev \
    texinfo \
    bison \
    flex \
    gettext \
    libelf-dev \
    libmpfr-dev \
    libmpc-dev \
    libgmp-dev \
    libisl-dev \
    dialog \
    lzop \
    squashfs-tools \
    mtd-utils \
    genext2fs \
    e2fsprogs \
    dosfstools \
    mtools \
    fakeroot \
    diffstat \
    chrpath \
    python3-pexpect \
    python3-git \
    python3-jinja2 \
    python3-subunit \
    zstd \
    liblz4-tool \
    debianutils \
    libsdl2-dev \
    mesa-common-dev \
    libglu1-mesa-dev \
    xterm \
    gcc-multilib \
    g++-multilib \
    lib32z1-dev \
    libc6-dev-i386 \
    pylint \
    rpcsvc-proto \
    lz4 \
    && rm -rf /var/lib/apt/lists/*

# Network packet analysis (wireshark-common includes editcap, mergecap, capinfos, etc.)
# Deep pcap analysis: termshark (TUI wireshark), tcptrace, tcpstat, ssldump, tcpick,
#   tcpxtract/foremost (file extraction), chaosreader/httpry (session reconstruction),
#   netsniff-ng (high-perf toolkit), suricata (offline IDS),
#   nfdump/argus-client (flow analysis), p0f (passive fingerprinting), sngrep (SIP/VoIP),
#   dnstop (DNS analysis), hping3 (packet crafting), dsniff (network audit suite)
# Python + headless browser deps (Playwright provides its own Chromium).
# NOTE (deviation): Node.js is NOT installed here — it comes from NodeSource 22.x
#   in the next step (Codex requires Node >= 22; Ubuntu's apt nodejs is 18.x).
# Java Runtime (JRE only — JDK dropped to save ~50 MB; only needed for tabula-py)
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libpcap-dev \
    tshark \
    wireshark-common \
    wireshark-doc \
    tcpreplay \
    tcpflow \
    ngrep \
    libnet1-dev \
    libnl-3-dev \
    libnl-genl-3-dev \
    libnl-route-3-dev \
    libnetfilter-queue-dev \
    libgeoip-dev \
    ethtool \
    ipset \
    conntrack \
    termshark \
    tcptrace \
    tcpstat \
    ssldump \
    tcpick \
    tcpxtract \
    chaosreader \
    foremost \
    httpry \
    netsniff-ng \
    hping3 \
    p0f \
    dsniff \
    sngrep \
    dnstop \
    nbtscan \
    httping \
    nfdump \
    argus-client \
    suricata \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    python3-setuptools \
    python3-wheel \
    xvfb \
    xauth \
    dbus \
    libx11-xcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxi6 \
    libxtst6 \
    libxrandr2 \
    libasound2t64 \
    libatk1.0-0t64 \
    libatk-bridge2.0-0t64 \
    libcups2t64 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0t64 \
    libnspr4 \
    libnss3 \
    libxss1 \
    libappindicator3-1 \
    fonts-liberation \
    xdg-utils \
    libu2f-udev \
    libvulkan1 \
    tidy \
    libxml2-utils \
    xmlstarlet \
    default-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 from NodeSource.
# DEVIATION FROM UPSTREAM: upstream installs Ubuntu's apt `nodejs` (18.x on noble).
# OpenAI Codex (installed near the end) requires Node >= 22, and every global npm
# tool below runs happily on 22 LTS, so we standardize on NodeSource 22.x. The
# NodeSource setup script runs its own apt-get update; `nodejs` here bundles npm.
#
# Pin npm's global prefix to /usr/local — where Ubuntu's apt npm puts globals
# (upstream's working behavior). NodeSource's npm otherwise defaults the prefix to
# /usr, and symlinking package bins into the crowded /usr/bin collides with
# apt-provided binaries (e.g. /usr/bin/markdown-it), which modern npm refuses to
# overwrite. /usr/local/bin is clean, on PATH, and survives the /home/user mount.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm config set prefix /usr/local \
    && node --version && npm --version

# Bun JavaScript/TypeScript runtime (installed system-wide into /usr/local)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash

# npm packages (browser automation, scraping, utilities, dev tools)
RUN npm install -g \
    puppeteer \
    playwright \
    cheerio \
    jsdom \
    axios \
    node-fetch \
    got \
    undici \
    turndown \
    readability-cli \
    linkedom \
    dompurify \
    sanitize-html \
    html-minifier-terser \
    clean-css-cli \
    terser \
    uglify-js \
    js-beautify \
    prettier \
    eslint \
    typescript \
    ts-node \
    tsx \
    esbuild \
    webpack-cli \
    webpack \
    vite \
    rollup \
    babel-cli \
    nodemon \
    pm2 \
    express \
    fastify \
    zod \
    lodash \
    underscore \
    ramda \
    date-fns \
    moment \
    dayjs \
    uuid \
    nanoid \
    chalk \
    commander \
    yargs \
    inquirer \
    ora \
    boxen \
    sharp \
    jimp \
    pdf-lib \
    pdfkit \
    csv-parser \
    csv-stringify \
    xlsx \
    json5 \
    yaml \
    toml \
    dotenv \
    marked \
    markdown-it \
    highlight.js \
    mermaid \
    @mermaid-js/mermaid-cli \
    md-to-pdf \
    d3 \
    puppeteer-extra \
    puppeteer-extra-plugin-stealth \
    http-server \
    live-server \
    concurrently \
    cross-env \
    rimraf \
    glob \
    minimatch \
    semver \
    debug \
    fx \
    json-diff \
    json-server \
    serve \
    localtunnel \
    degit \
    svgo \
    npm-check-updates \
    depcheck \
    madge \
    license-checker \
    tree-sitter-cli \
    wappalyzer \
    tldr \
    speed-test \
    is-up-cli \
    public-ip-cli \
    internal-ip-cli \
    fkill-cli \
    empty-trash-cli \
    clipboard-cli \
    open-cli

# Libraries: image processing, PDF, graphics, ICU, crypto, OCR, documents
RUN apt-get update && apt-get install -y \
    libjpeg-dev \
    libpng-dev \
    libtiff-dev \
    libwebp-dev \
    libopenjp2-7-dev \
    libfreetype6-dev \
    zlib1g-dev \
    libffi-dev \
    libssl-dev \
    libxml2-dev \
    libxslt1-dev \
    libcairo2-dev \
    libpango1.0-dev \
    libgdk-pixbuf2.0-dev \
    libglib2.0-dev \
    librsvg2-dev \
    libmagic1 \
    libmagickwand-dev \
    libicu-dev \
    icu-devtools \
    libfribidi-dev \
    libharfbuzz-dev \
    libsodium-dev \
    libgcrypt20-dev \
    libgnutls28-dev \
    libargon2-dev \
    libnss3-dev \
    libsasl2-dev \
    libkrb5-dev \
    libscrypt-dev \
    libsecret-1-dev \
    gnutls-bin \
    p11-kit \
    softhsm2 \
    tesseract-ocr \
    tesseract-ocr-heb \
    tesseract-ocr-ara \
    tesseract-ocr-eng \
    tesseract-ocr-rus \
    tesseract-ocr-fra \
    tesseract-ocr-deu \
    tesseract-ocr-spa \
    libtesseract-dev \
    leptonica-progs \
    poppler-utils \
    libpoppler-dev \
    libpoppler-cpp-dev \
    ghostscript \
    qpdf \
    pandoc \
    wkhtmltopdf \
    sqlite3 \
    libsqlite3-dev \
    postgresql-client \
    libpq-dev \
    redis-tools \
    liblapack-dev \
    libblas-dev \
    libopenblas-dev \
    libhdf5-dev \
    libgeos-dev \
    libproj-dev \
    libgdal-dev \
    && rm -rf /var/lib/apt/lists/*

# LibreOffice (minimal: writer + calc for doc conversion, dropped impress + draw to save ~600 MB)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libreoffice-writer \
    libreoffice-calc \
    && rm -rf /var/lib/apt/lists/*

# Multimedia, audio, video, graphs, fonts
RUN apt-get update && apt-get install -y \
    ffmpeg \
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev \
    libavutil-dev \
    libavfilter-dev \
    libavdevice-dev \
    imagemagick \
    sox \
    libsox-dev \
    libsox-fmt-all \
    mediainfo \
    libmediainfo-dev \
    libsndfile1-dev \
    vorbis-tools \
    lame \
    flac \
    opus-tools \
    mkvtoolnix \
    exiftool \
    webp \
    optipng \
    pngquant \
    jpegoptim \
    gifsicle \
    graphviz \
    libgraphviz-dev \
    gnuplot \
    fonts-dejavu \
    fonts-dejavu-core \
    fonts-dejavu-extra \
    fonts-liberation \
    fonts-liberation2 \
    fonts-noto \
    fonts-noto-color-emoji \
    fonts-noto-mono \
    fonts-noto-extra \
    fonts-noto-cjk \
    fonts-noto-cjk-extra \
    fonts-noto-ui-core \
    fonts-noto-ui-extra \
    fonts-freefont-ttf \
    fonts-opensymbol \
    fonts-open-sans \
    fonts-roboto \
    fonts-firacode \
    fonts-hack \
    culmus \
    culmus-fancy \
    fonts-hosny-amiri \
    fonts-arabeyes \
    fonts-kacst \
    fonts-kacst-one \
    fonts-droid-fallback \
    fonts-indic \
    fonts-thai-tlwg \
    fontconfig \
    fonts-symbola \
    fonts-powerline \
    fonts-font-awesome \
    fonts-ubuntu \
    fonts-ubuntu-console \
    fonts-cascadia-code \
    fonts-jetbrains-mono \
    fonts-lato \
    fonts-material-design-icons-iconfont \
    fonts-emojione \
    fonts-ancient-scripts \
    fonts-wine \
    fonts-ibm-plex \
    fonts-cantarell \
    fonts-crosextra-carlito \
    fonts-crosextra-caladea \
    fonts-nanum \
    fonts-nanum-coding \
    fonts-nanum-eco \
    fonts-nanum-extra \
    fonts-urw-base35 \
    fonts-sil-gentium-basic \
    fonts-sil-charis \
    fonts-wqy-microhei \
    fonts-wqy-zenhei \
    fonts-arphic-ukai \
    fonts-arphic-uming \
    fonts-ipafont-gothic \
    fonts-ipafont-mincho \
    fonts-vlgothic \
    fonts-takao-gothic \
    fonts-unfonts-core \
    fonts-unfonts-extra \
    fonts-sil-padauk \
    fonts-sil-abyssinica \
    fonts-lklug-sinhala \
    fonts-tibetan-machine \
    fonts-guru \
    fonts-guru-extra \
    fonts-lohit-guru \
    fonts-tlwg-garuda \
    fonts-tlwg-kinnari \
    fonts-tlwg-laksaman \
    fonts-tlwg-loma \
    fonts-tlwg-mono \
    fonts-tlwg-norasi \
    fonts-tlwg-purisa \
    fonts-tlwg-sawasdee \
    fonts-tlwg-typewriter \
    fonts-tlwg-typist \
    fonts-tlwg-typo \
    fonts-tlwg-umpush \
    fonts-tlwg-waree \
    xfonts-utils \
    && rm -rf /var/lib/apt/lists/* && fc-cache -fv

# PlantUML (uses graphviz + default-jre-headless already installed above)
RUN curl -fsSL -o /usr/local/lib/plantuml.jar \
      https://github.com/plantuml/plantuml/releases/download/v1.2025.0/plantuml-1.2025.0.jar \
    && printf '#!/bin/sh\nexec java -jar /usr/local/lib/plantuml.jar "$@"\n' > /usr/local/bin/plantuml \
    && chmod +x /usr/local/bin/plantuml

# Terminal libraries, codecs (GStreamer dropped to save ~200 MB), language packs
# Language packs available but do NOT change the default LANG/LC_ALL (C.UTF-8 supports full Unicode/emoji)
RUN apt-get update && apt-get install -y \
    ncurses-term \
    libncursesw6 \
    ncurses-doc \
    libslang2-dev \
    libnotcurses-dev \
    notcurses-bin \
    libvterm-dev \
    libtermkey-dev \
    libtickit-dev \
    libcaca-dev \
    caca-utils \
    libaa1-dev \
    aalib1 \
    libnewt-dev \
    libreadline-dev \
    libedit-dev \
    libunistring-dev \
    libunibilium-dev \
    libutf8proc-dev \
    libfmt-dev \
    whiptail \
    figlet \
    toilet \
    toilet-fonts \
    cowsay \
    boxes \
    fortune-mod \
    cmatrix \
    sl \
    lolcat \
    libavcodec-extra \
    libx264-dev \
    libx265-dev \
    libvpx-dev \
    libopus-dev \
    libaom-dev \
    libdav1d-dev \
    libde265-dev \
    libtheora-dev \
    libspeex-dev \
    libmp3lame-dev \
    libogg-dev \
    libvorbis-dev \
    libflac-dev \
    libwavpack-dev \
    language-pack-en \
    language-pack-he \
    language-pack-ar \
    language-pack-zh-hans \
    language-pack-ja \
    language-pack-ko \
    language-pack-ru \
    language-pack-fr \
    language-pack-de \
    language-pack-es \
    language-pack-pt \
    language-pack-hi \
    language-pack-it \
    language-pack-pl \
    language-pack-tr \
    language-pack-uk \
    && rm -rf /var/lib/apt/lists/*

# Generate locales (Hebrew, Arabic, and common)
# NOTE: Does NOT change the default locale (C.UTF-8), just makes these available
RUN locale-gen en_US.UTF-8 he_IL.UTF-8 ar_SA.UTF-8 ru_RU.UTF-8 fr_FR.UTF-8 \
    de_DE.UTF-8 es_ES.UTF-8 zh_CN.UTF-8 ja_JP.UTF-8 ko_KR.UTF-8 \
    hi_IN.UTF-8 pt_BR.UTF-8 it_IT.UTF-8 pl_PL.UTF-8 tr_TR.UTF-8 uk_UA.UTF-8

# ============================================================
# TERMINAL AGENT TOOLS
# Tools that a CLI-based AI agent frequently uses
# ============================================================

# Agent essentials: search, text processing, structured data, automation, language runtimes
RUN apt-get update && apt-get install -y \
    silversearcher-ag \
    cloc \
    shellcheck \
    shfmt \
    expect \
    moreutils \
    inotify-tools \
    procps \
    util-linux \
    coreutils \
    groff \
    wdiff \
    highlight \
    source-highlight \
    pigz \
    pbzip2 \
    pixz \
    asciinema \
    direnv \
    apache2-utils \
    miller \
    csvtool \
    xml-twig-tools \
    html-xml-utils \
    neovim \
    micro \
    fish \
    btop \
    mc \
    ranger \
    nnn \
    vifm \
    trash-cli \
    xclip \
    xsel \
    golang-go \
    rustc \
    cargo \
    ruby \
    ruby-dev \
    perl \
    lua5.4 \
    liblua5.4-dev \
    luarocks \
    lua-lpeg \
    lua-cjson \
    lua-socket \
    lua-filesystem \
    lua-sec \
    r-base-core \
    && rm -rf /var/lib/apt/lists/*

# Lua extras for Wireshark custom dissector development
# luarocks packages for binary protocol parsing and data manipulation
RUN luarocks install struct && \
    luarocks install lua-zlib && \
    luarocks install lua-messagepack && \
    luarocks install luabitop

# GitHub CLI (gh) - essential for agents interacting with GitHub
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# glow (Charmbracelet — markdown reader)
RUN wget -qO /tmp/glow.deb https://github.com/charmbracelet/glow/releases/download/v2.0.0/glow_2.0.0_amd64.deb && dpkg -i /tmp/glow.deb && rm /tmp/glow.deb

# rclone (cloud storage swiss army knife)
RUN curl -fsSL https://rclone.org/install.sh | bash

# Azure CLI
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash && \
    rm -rf /var/lib/apt/lists/* && \
    az extension add --name azure-devops 2>/dev/null || true

# ============================================================
# PYTHON PACKAGES (consolidated into larger groups)
# ============================================================

# Fix system packages and install base
RUN find /usr/lib/python3/dist-packages /usr/lib/python3.12/dist-packages \
        -name '*.dist-info' -type d ! -exec test -f '{}/RECORD' \; -exec rm -rf '{}' + 2>/dev/null; \
    pip3 install --break-system-packages --no-cache-dir setuptools wheel packaging charset-normalizer && \
    pip3 install --break-system-packages --no-cache-dir --upgrade pbr

# Data processing, analysis, visualization
RUN pip3 install --break-system-packages --no-cache-dir \
    numpy scipy pandas polars pyarrow "dask[complete]" "modin[dask]" xarray sympy statsmodels \
    more-itertools toolz cytoolz joblib orjson ujson pyyaml toml tomli tomli-w \
    python-dateutil arrow pendulum pytz chardet charset-normalizer tabulate prettytable tqdm \
    numba cython numexpr bottleneck swifter pandarallel \
    missingno ydata-profiling sweetviz pandera great-expectations \
    matplotlib seaborn plotly bokeh altair vega_datasets pygal wordcloud graphviz networkx pydot \
    plotnine holoviews hvplot datashader colorcet panel streamlit gradio nicegui

# PDF, documents, RTL text, Azure, Office formats
RUN pip3 install --break-system-packages --no-cache-dir \
    pypdf PyPDF2 pdfplumber "pdfminer.six" PyMuPDF pikepdf reportlab fpdf2 weasyprint xhtml2pdf \
    borb pdfrw img2pdf svglib "camelot-py[cv]" tabula-py pdf2image ocrmypdf pdf2docx \
    python-bidi arabic-reshaper PyICU pyfribidi hebrew-tokenizer camel-tools \
    azure-devops azure-cli-core azure-identity azure-storage-blob azure-storage-file-share msrest msal \
    openpyxl xlrd xlsxwriter xlwt odfpy python-docx python-pptx python-calamine mammoth docx2txt striprtf ebooklib csvkit petl \
    pypandoc markdownify html2text filetype python-magic xmltodict dicttoxml \
    mwclient mwparserfromhell wikitextparser

# Multimedia, OCR, image processing
RUN pip3 install --break-system-packages --no-cache-dir \
    moviepy ffmpeg-python pydub librosa soundfile audioread imageio-ffmpeg \
    pytesseract Pillow opencv-python-headless scikit-image rawpy imageio Wand albumentations imgaug

# PyTorch CPU-only (installed first to prevent 700 MB+ default wheel)
RUN pip3 install --break-system-packages --no-cache-dir \
    torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

# OCR, search, LLM, ML
RUN pip3 install --break-system-packages --no-cache-dir --no-deps easyocr && \
    pip3 install --break-system-packages --no-cache-dir easyocr \
    rank-bm25 whoosh lunr faiss-cpu annoy hnswlib chromadb sentence-transformers txtai \
    openai anthropic huggingface-hub datasets transformers tokenizers sentencepiece tiktoken onnx onnxruntime \
    scikit-learn xgboost lightgbm catboost imbalanced-learn feature-engine category_encoders \
    optuna hyperopt shap lime eli5 mlflow

# NLP, statistics, web scraping
RUN pip3 install --break-system-packages --no-cache-dir \
    nltk spacy gensim textblob langdetect regex rapidfuzz "fuzzywuzzy[speedup]" ftfy unidecode python-Levenshtein polyglot wordfreq \
    pingouin lifelines arviz emcee uncertainties \
    requests "httpx[http2]" aiohttp beautifulsoup4 lxml cssselect html5lib scrapy parsel feedparser urllib3 \
    selenium playwright pyppeteer splinter mechanicalsoup grab httpcore

# HTML parsing, database, web frameworks
RUN pip3 install --break-system-packages --no-cache-dir \
    html5-parser bleach nh3 selectolax pyquery tinycss2 cssutils css-parser premailer \
    html-sanitizer htmlmin minify-html lxml-html-clean readability-lxml trafilatura newspaper3k boilerpy3 w3lib tldextract validators \
    sqlalchemy alembic psycopg2-binary asyncpg redis pymongo motor peewee dataset "databases[sqlite,postgresql]" duckdb lancedb \
    flask flask-cors flask-sqlalchemy flask-login flask-wtf flask-restful flask-socketio flask-talisman \
    django django-cors-headers djangorestframework fastapi "uvicorn[standard]" starlette gunicorn dash tornado \
    aiofiles websockets waitress hypercorn daphne twisted sanic falcon bottle cherrypy pyramid hug responder \
    werkzeug httptools h11 h2 wsproto uvloop python-socketio channels gevent eventlet pyopenssl trustme

# CLI, TUI, dev tools, testing, profiling, Jupyter
RUN pip3 install --break-system-packages --no-cache-dir \
    click typer rich pydantic loguru structlog tenacity retry environs colorama termcolor blessed \
    prompt-toolkit questionary alive-progress yaspin humanize inflect natsort semver \
    textual textual-dev urwid npyscreen asciimatics pytermgui curtsies wcwidth emoji unicodedata2 \
    pyfiglet art asciichartpy plotext drawille colored blessings sty ansicolors colorful pastel termtables terminaltables \
    tox nox black ruff isort flake8 mypy pylint bandit safety vulture pyflakes autopep8 yapf pre-commit \
    pytest pytest-cov pytest-asyncio pytest-xdist pytest-mock pytest-benchmark hypothesis coverage faker factory-boy responses vcrpy freezegun time-machine \
    ipython ipdb pygments memory-profiler line-profiler scalene snakeviz py-spy objgraph pympler \
    jupyter jupyterlab notebook nbconvert nbformat ipywidgets ipykernel jupytext papermill nbstripout

# Crypto, geo, cloud, serialization, config, utilities
# NOTE: `supervisor` here provides supervisord — the process manager that runs
#       the desktop stack (Xvfb/XFCE/pulseaudio/rustdesk) at container runtime.
RUN pip3 install --break-system-packages --no-cache-dir \
    cryptography pynacl pycryptodome pycryptodomex bcrypt argon2-cffi passlib hashids pyjwt "python-jose[cryptography]" \
    itsdangerous asn1crypto pyotp qrcode keyring paramiko fabric python-gnupg certifi cffi \
    truststore certvalidator oscrypto tls-parser sslyze tlslite-ng scrypt jwcrypto \
    shapely geopandas folium pyproj fiona rasterio geopy \
    boto3 google-cloud-storage python-dotenv python-multipart jinja2 mako markdown python-markdown-math celery dramatiq apscheduler watchdog luigi prefect \
    h5py tables fastparquet msgpack cbor2 protobuf flatbuffers lz4 zstandard brotli python-snappy avro fastavro \
    attrs cattrs dataclasses-json marshmallow cerberus dynaconf python-decouple omegaconf hydra-core typeguard beartype \
    sh plumbum invoke doit psutil supervisor gitpython pygithub dulwich \
    cachetools diskcache dogpile.cache aiocache trio anyio \
    boltons funcy pydash returns multipledispatch bidict sortedcontainers intervaltree bitarray mmh3 xxhash pybloom-live datasketch

# Financial, PCAP, agent tools
RUN pip3 install --break-system-packages --no-cache-dir \
    yfinance pandas-ta prophet arch pmdarima tslearn sktime \
    scapy dpkt pyshark kamene pcapng python-pcapng impacket netaddr ipaddress netifaces nfstream \
    bpython ptpython xonsh jupyter-console litecli pgcli mycli iredis \
    glances ansible ansible-lint molecule \
    tldr howdoi thefuck cookiecutter copier cruft bump2version semantic-version twine build flit hatch pdm poetry \
    openapi-spec-validator jsonschema prance apispec flasgger datamodel-code-generator sqlacodegen \
    watchfiles inotify-simple deepdiff dictdiffer jsonpatch jsonpointer unidiff patch-ng \
    pexpect ptyprocess sarge delegator.py python-crontab schedule rq huey

# Download NLTK data & spaCy models
RUN python3 -c "import nltk; nltk.download('punkt'); nltk.download('punkt_tab'); nltk.download('stopwords'); nltk.download('wordnet'); nltk.download('averaged_perceptron_tagger'); nltk.download('averaged_perceptron_tagger_eng'); nltk.download('vader_lexicon'); nltk.download('maxent_ne_chunker'); nltk.download('maxent_ne_chunker_tab'); nltk.download('words'); nltk.download('omw-1.4'); nltk.download('universal_tagset')" && \
    PIP_BREAK_SYSTEM_PACKAGES=1 python3 -m spacy download en_core_web_sm && \
    PIP_BREAK_SYSTEM_PACKAGES=1 python3 -m spacy download en_core_web_md

# Install Playwright browsers (Chromium + Firefox) for headless browser automation
# This pre-downloads browser binaries so they work offline
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN playwright install --with-deps chromium firefox && \
    npx playwright install chromium firefox && \
    chmod -R a+rX /opt/playwright-browsers

# Puppeteer: skip its own Chromium download, reuse Playwright's (~400 MB saved)
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/opt/playwright-browsers/chromium-*/chrome-linux/chrome

# Convenience symlinks
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd && \
    ln -sf /usr/bin/batcat /usr/local/bin/bat

# ============================================================
# BUILD TTYD FROM SOURCE
# ============================================================
# ttyd is vendored as an available terminal tool (built from source for OSC 52
# clipboard support). NOTE: unlike upstream we do NOT serve it — there is no
# `EXPOSE 7681` / ttyd CMD; the desktop is delivered over RustDesk. The binary is
# simply present for anyone who wants a local web terminal.
# Released 1.7.7 bundles xterm.js 5.4.0 without the clipboard addon.
# Commit 9c87671 on main includes @xterm/addon-clipboard for OSC 52 browser clipboard.

# ttyd build dependencies
RUN apt-get update && apt-get install -y \
    libjson-c-dev \
    libuv1-dev \
    && rm -rf /var/lib/apt/lists/*

# Build libwebsockets 4.3.6 with libuv support (required by ttyd)
RUN git clone --depth 1 --branch v4.3.6 https://github.com/warmcat/libwebsockets.git /tmp/lws && \
    mkdir /tmp/lws/build && cd /tmp/lws/build && \
    cmake .. \
        -DLWS_WITH_LIBUV=ON \
        -DLWS_WITHOUT_CLIENT=ON \
        -DLWS_WITH_HTTP2=ON \
        -DCMAKE_BUILD_TYPE=Release && \
    make -j$(nproc) && make install && ldconfig && \
    rm -rf /tmp/lws

# Build ttyd: frontend (xterm.js 5.5.0 + clipboard addon) then C backend
# Commit 9c87671 includes @xterm/addon-clipboard for OSC 52 browser clipboard
RUN git clone https://github.com/tsl0922/ttyd.git /tmp/ttyd && \
    cd /tmp/ttyd && git checkout 9c87671ccae9eefa3c01b08169272c0922e7cdff && \
    npm install -g corepack && corepack enable && \
    cd /tmp/ttyd/html && yarn install && yarn build && \
    mkdir /tmp/ttyd/build && cd /tmp/ttyd/build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make -j$(nproc) && \
    cp ttyd /usr/local/bin/ttyd && \
    rm -rf /tmp/ttyd

# ============================================================
# BINARY REVERSE-ENGINEERING TOOLCHAIN
# Static-analysis tools for Windows / Linux / macOS binaries (PE, ELF,
# Mach-O, LE) plus extraction utilities for common installer wrappers
# (InstallShield, Inno Setup, NSIS, MSI, Microsoft Cabinet).
# ============================================================

# Installer-payload extraction tools + OpenJDK 21 JDK.
# Ghidra needs the full JDK (it invokes javac at startup); the
# default-jre-headless installed earlier is not sufficient on its own.
# 7zip 23.01 is the real (non-transitional) Ubuntu noble package — binary
# is /usr/bin/7zz, not /usr/bin/7z; the p7zip-full installed earlier is a
# transitional alias that pulls in this same package.
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jdk-headless \
    7zip=23.01+dfsg-11 \
    binwalk=2.3.4+dfsg1-5 \
    cabextract=1.11-2 \
    innoextract=1.9-0.1build1 \
    unshield=1.5.1-1 \
    && rm -rf /var/lib/apt/lists/*

# radare2 6.1.4 — CLI reverse-engineering framework (built from source via ACR)
# Pinned to commit 4661541e40947fbc269b0c2686d1cd52ad69c1dc for reproducibility.
# Built with --with-rpath so the binary is self-contained under /opt/radare2.
RUN git clone --depth 1 --branch 6.1.4 https://github.com/radareorg/radare2 /tmp/r2 \
    && cd /tmp/r2 \
    && actual=$(git rev-parse HEAD) \
    && [ "$actual" = "4661541e40947fbc269b0c2686d1cd52ad69c1dc" ] \
        || (echo "radare2 commit drift: expected 4661541e..., got $actual" && exit 1) \
    && CFLAGS="-O2" LDFLAGS="-Wl,--as-needed" \
       ./configure --prefix=/opt/radare2 --with-rpath \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/r2

ENV PATH="/opt/radare2/bin:$PATH"

# Ghidra 12.0.4 PUBLIC build 20260303 — open-source reverse-engineering suite.
# SHA-256-verified download from the official GitHub release.
RUN curl -fsSL -o /tmp/ghidra.zip \
        https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.0.4_build/ghidra_12.0.4_PUBLIC_20260303.zip \
    && echo "c3b458661d69e26e203d739c0c82d143cc8a4a29d9e571f099c2cf4bda62a120  /tmp/ghidra.zip" \
        | sha256sum --check --status \
    && unzip -q /tmp/ghidra.zip -d /opt \
    && mv /opt/ghidra_12.0.4_PUBLIC /opt/ghidra \
    && rm /tmp/ghidra.zip

ENV GHIDRA_INSTALL_DIR=/opt/ghidra
ENV PATH="/opt/ghidra/support:$PATH"

# Python packages for PE / binary / installer static analysis.
#   pefile      Microsoft Portable Executable parser (import/export tables,
#               sections, headers, version info)
#   lief        Multi-format binary parser (PE, ELF, Mach-O, OAT, DEX)
#   capstone    Intel x86 / AMD64 / ARM / MIPS disassembly engine
#   r2pipe      JSON-pipe bindings to a running radare2 instance
#   pyghidra    CPython binding to the Ghidra programmatic API
#   JPype1      Java/Python bridge (transitively required by pyghidra)
RUN pip3 install --break-system-packages --no-cache-dir \
    pefile==2024.8.26 \
    lief==0.17.6 \
    capstone==5.0.7 \
    r2pipe==1.9.8 \
    JPype1==1.5.2 \
    pyghidra==3.0.2

# uv (Astral) — fast Python package/project manager.
# DEVIATION FROM UPSTREAM: installed system-wide into /usr/local/bin (not the
# per-user ~/.local/bin), because /home/user is a runtime bind-mount that would
# otherwise shadow a per-user install. Build fails loud if uv didn't land there.
RUN curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
    && test -x /usr/local/bin/uv

# ============================================================
# CODING AGENTS
# ============================================================

# OpenCode CLI — community MIT-licensed terminal coding agent, kept as an
# available tool. We install ONLY the binary; the upstream's Ollama provider
# config + air-gap env are intentionally dropped (they pointed at a
# 172.17.0.1:11434 Ollama that does not exist here). Haggai's primary agent is
# OpenAI Codex (below); he can point OpenCode at his own provider if he wants it.
RUN npm install -g opencode-ai@1.1.53

# OpenAI Codex CLI — Haggai's primary coding agent.
# Installed system-wide (survives the /home/user bind-mount); requires Node >= 22
# (NodeSource, above). First-run auth (device-code "Sign in with ChatGPT" or
# OPENAI_API_KEY) is done by Haggai inside the desktop and persists in ~/.codex.
# The container is Codex's sandbox boundary — config/codex/config.toml sets
# sandbox_mode="danger-full-access" and is seeded into ~/.codex by the entrypoint.
RUN npm install -g @openai/codex

# T3 Code — a web GUI for coding agents. It wraps the already-installed Codex CLI
# and serves a browser UI; run `t3 --host 0.0.0.0 --port 3773 --no-browser` when
# you intentionally want it reachable through the published T3 Code port.
RUN npm install -g t3@0.0.28 \
    && t3 --version

# ============================================================
# REMOTE DESKTOP — RustDesk client (Direct IP Access) + X11 desktop
# ============================================================
# Pure X11 on purpose (Xvfb + XFCE, NO Wayland): RustDesk captures the X server
# directly, so unattended access needs only the permanent-password config (there
# is no xdg-desktop-portal consent dialog on X11). Software video encoding only
# (enable-hwcodec='N' in config/RustDesk2.toml) — this container never touches
# the NVIDIA GPU.

# XFCE desktop + virtual X server tooling + session bus + audio.
# (xvfb / xauth / dbus are already pulled in by the toolchain above.)
RUN apt-get update && apt-get install -y \
    xfce4 \
    xfce4-terminal \
    xfce4-goodies \
    dbus-x11 \
    x11-xserver-utils \
    x11-utils \
    pulseaudio \
    && rm -rf /var/lib/apt/lists/*

# Disable two XFCE autostarts that are wrong for a HEADLESS, RustDesk-streamed
# desktop: xscreensaver would blank the captured framebuffer, and light-locker would
# lock the session (a remote lock-out risk). Marking them Hidden=true makes
# xfce4-session ignore them; the binaries stay installed, this only stops autostart.
RUN set -e; for f in xscreensaver light-locker; do \
      d="/etc/xdg/autostart/$f.desktop"; \
      if [ -f "$d" ]; then \
        printf '\n# Disabled for haggai_computer (headless): no screen to blank or lock.\nHidden=true\n' >> "$d"; \
        echo "disabled autostart: $d"; \
      fi; \
    done

# RustDesk — THE HARDENED FORK, not upstream 1.4.7. Instead of upstream's release we
# download our fork's reproducible (double-build A==B) .deb straight from its published
# GitHub release, pinned + fail-closed by SHA-256 — the exact release asset for tag
# commit-8179a3bae952 (fork v1.4.7-hardened.1). The build aborts on any SHA / package-
# metadata mismatch, so a wrong or tampered asset can never install; we also grep
# the installed library for the CPace fork marker so a clean rebuild cannot silently
# fall back to upstream. The fork keeps Package=rustdesk / Version=1.4.7 (it forks
# 1.4.7) and installs to /usr/share/rustdesk/rustdesk, so every downstream path/service
# is unchanged. The fork REPLACES upstream's plaintext direct-IP path with a mandatory
# CPace PAKE (so it is NOT wire-compatible with the stock RustDesk app — the viewer
# must be the fork's client too), compile-pins the direct port to 21118, the display
# server to X11, and the whole security policy (verification-method / approve-mode /
# access-mode / hwcodec-off), and excises the rendezvous/relay/updater/plugin paths —
# which makes several of this Dockerfile's workarounds below inert (documented at each).
# `apt install ./<deb>` resolves Noble's t64 transitional aliases.
ARG RUSTDESK_VERSION=1.4.7
# The release asset URL and its SHA-256 are ONE pinned identity — to move to a newer
# fork build, bump both together (the tag in the URL and the hash).
ARG RUSTDESK_DEB_URL=https://github.com/BigBIueWhale/rustdesk_fork/releases/download/commit-8179a3bae952/rustdesk-x86_64.deb
ARG RUSTDESK_DEB_SHA256=2c600ffb74ba86eb5c996243d09ee75435c1080c65114d870a4fdcb1f72344bd
RUN curl -fsSL -o /tmp/rustdesk.deb "${RUSTDESK_DEB_URL}" \
    && echo "${RUSTDESK_DEB_SHA256}  /tmp/rustdesk.deb" | sha256sum --check --status \
    && [ "$(dpkg-deb --field /tmp/rustdesk.deb Package)" = "rustdesk" ] \
    && [ "$(dpkg-deb --field /tmp/rustdesk.deb Version)" = "${RUSTDESK_VERSION}" ] \
    && apt-get update && apt-get install -y /tmp/rustdesk.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/rustdesk.deb \
    && test -x /usr/share/rustdesk/rustdesk \
    && grep -a -q 'rustdesk-fork/CPace' /usr/share/rustdesk/lib/librustdesk.so

# Force RustDesk's Linux display-server detection to X11. In this container
# `loginctl` may exist with no login1 session, so RustDesk's get_display_server()
# would fall back to $XDG_SESSION_TYPE; a stray non-x11 value makes `--server`
# REFUSE incoming sessions ("Unsupported display server type") and mis-select the
# capture/input backend. Forcing x11 makes it deterministic. (Verified against the
# 1.4.7 source: hbb_common platform/linux.rs honors this env var first.)
ENV RUSTDESK_FORCED_DISPLAY_SERVER=x11

# ============================================================
# DESKTOP GUI APPS — Firefox, Chrome, VS Code (real .deb, never snaps)
# ============================================================
# On Ubuntu 24.04 `apt install firefox` / `chromium` pull snap STUBS, and snapd
# cannot run in this non-systemd container. So we install the upstream .deb builds
# from each vendor's official APT repo:
#   * Firefox — Mozilla's repo, PINNED above Ubuntu's snap stub so a later
#     `apt install firefox` keeps resolving to the real .deb (not the snap).
#   * Google Chrome — Google's repo.
#   * VS Code (`code`) — Microsoft's repo.
# All render in software (this container never touches the GPU). Sandboxing note:
# Chrome and VS Code are Chromium/Electron; their renderer sandboxes want unprivileged
# user namespaces, which Ubuntu 24.04 restricts by default
# (kernel.apparmor_restrict_unprivileged_userns) and which we do NOT re-enable
# host-wide. Consistent with the Codex decision in docs/SECURITY.md (the CONTAINER is
# the isolation boundary), Chrome and Code launch with --no-sandbox; Firefox falls
# back to its seccomp-only content sandbox on its own.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
         -o /etc/apt/keyrings/packages.mozilla.org.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
         > /etc/apt/sources.list.d/mozilla.list \
    && printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
         > /etc/apt/preferences.d/mozilla \
    && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
         -o /etc/apt/keyrings/google-chrome.asc \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main" \
         > /etc/apt/sources.list.d/google-chrome.list \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
         -o /etc/apt/keyrings/microsoft.asc \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.asc] https://packages.microsoft.com/repos/code stable main" \
         > /etc/apt/sources.list.d/vscode.list \
    && apt-get update \
    && apt-get install -y firefox google-chrome-stable code \
    && rm -rf /var/lib/apt/lists/* \
    && test -x /usr/bin/firefox \
    && test -x /usr/bin/google-chrome-stable \
    && test -x /usr/bin/code

# Chrome and VS Code (Chromium/Electron) can't initialise their userns sandbox here,
# so launch them with --no-sandbox: a shim for each terminal command plus a patch to
# the Applications-menu launchers. Packaged binaries are left untouched (clean
# upgrades). Assertions fail the BUILD if a vendor changes its .desktop Exec, rather
# than shipping a menu icon that silently launches an unstartable app.
RUN set -e; \
    printf '#!/bin/sh\n# container is the sandbox here (docs/SECURITY.md)\nexec /usr/bin/google-chrome-stable --no-sandbox "$@"\n' \
      > /usr/local/bin/google-chrome; \
    chmod 0755 /usr/local/bin/google-chrome; \
    sed -ri 's#^Exec=/usr/bin/google-chrome(-stable)?#Exec=/usr/local/bin/google-chrome#' \
      /usr/share/applications/google-chrome.desktop; \
    grep -q '^Exec=/usr/local/bin/google-chrome' /usr/share/applications/google-chrome.desktop; \
    if grep -q '^Exec=/usr/bin/google-chrome' /usr/share/applications/google-chrome.desktop; then \
      echo 'ERROR: chrome .desktop still launches the un-wrapped binary'; exit 1; fi; \
    printf '#!/bin/sh\n# container is the sandbox here (docs/SECURITY.md)\nexec /usr/bin/code --no-sandbox "$@"\n' \
      > /usr/local/bin/code; \
    chmod 0755 /usr/local/bin/code; \
    for d in code code-url-handler; do f="/usr/share/applications/$d.desktop"; \
      [ -f "$f" ] && sed -ri 's#^Exec=/usr/share/code/code#Exec=/usr/share/code/code --no-sandbox#' "$f" || true; done; \
    grep -q -- '--no-sandbox' /usr/share/applications/code.desktop

# ============================================================
# OPTIONAL: dev mode — host Docker CLI + the docker-guard wrapper
# (build arg WITH_DEV, default 0 = OFF)
# ============================================================
# Baked in ONLY when built with --build-arg WITH_DEV=1, which `./setup.sh --dev`
# does via docker-compose.dev.yml. It installs the Docker *client* only (no daemon,
# no containerd) so that — with the host's /var/run/docker.sock bind-mounted in — the
# in-container dev environment drives the HOST's Docker (build/run/compose, incl.
# GPU/CUDA containers). It then installs dev/docker-guard as /usr/local/bin/docker so
# it SHADOWS the real CLI (/usr/bin/docker) on PATH and owns the leaky abstraction
# that `docker` here controls the HOST daemon — refusing the patterns that would
# publish a service to the public internet on this DMZ box (see dev/docker-guard and
# docs/SECURITY.md). Default 0 leaves Haggai's image with NO Docker client and NO
# wrapper at all. SECURITY: the host socket is root-equivalent; see docs/SECURITY.md
# and docker-compose.dev.yml.
#
# The guard is COPYed to a staging path first (a COPY itself can't be build-arg-
# conditional); the RUN then either installs it (dev) or removes it (default), so the
# default image is left clean.
COPY dev/docker-guard /usr/local/lib/haggai/docker-guard
ARG WITH_DEV=0
RUN if [ "$WITH_DEV" = "1" ]; then \
      set -eux; \
      install -m 0755 -d /etc/apt/keyrings; \
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; \
      chmod a+r /etc/apt/keyrings/docker.asc; \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
        > /etc/apt/sources.list.d/docker.list; \
      apt-get update; \
      apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
      rm -rf /var/lib/apt/lists/*; \
      test -x /usr/bin/docker; \
      chmod 0755 /usr/local/lib/haggai/docker-guard; \
      ln -sf /usr/local/lib/haggai/docker-guard /usr/local/bin/docker; \
      bash -n /usr/local/lib/haggai/docker-guard; \
      [ "$(command -v docker)" = /usr/local/bin/docker ] || { echo 'ERROR: docker-guard does not shadow /usr/bin/docker on PATH'; exit 1; }; \
    else \
      rm -f /usr/local/lib/haggai/docker-guard; \
      rmdir /usr/local/lib/haggai 2>/dev/null || true; \
      echo "WITH_DEV=0 (default) — no Docker CLI, no docker-guard"; \
    fi

# ============================================================
# USER SETUP
# ============================================================
# Interactive account `user` (uid 1000): a PASSWORD-REQUIRED sudoer.
#   * "root" in the operator's sense = can run `sudo`, NOT uid 0, NOT NOPASSWD.
#   * NO password is baked here — the account is locked until deploy. setup.sh
#     sets the Linux password (== the RustDesk permanent password) via chpasswd,
#     which is what unlocks both remote-desktop login and sudo.
# Ubuntu 24.04 ships an "ubuntu" user at uid 1000; remove it so `user` can take 1000.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -s /bin/bash -G sudo -u 1000 user

# ============================================================
# PROCESS SUPERVISION + RUNTIME CONFIG SEEDS
# ============================================================
# supervisord (the `supervisor` pip package above) runs the desktop stack, in
# order, all as `user`:  Xvfb -> pulseaudio -> XFCE(+dbus) -> rustdesk --server.
COPY supervisord.conf /etc/supervisor/haggai.conf
COPY rootfs/usr/local/bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/start-xvfb.sh \
             /usr/local/bin/start-xfce.sh \
             /usr/local/bin/start-pulseaudio.sh \
             /usr/local/bin/start-rustdesk.sh

# Skeleton configs. /home/user is a runtime bind-mount, so these cannot be baked
# into it at build time; the entrypoint copies them into the user's home on first
# run (idempotent, only if absent), then chowns them to `user`.
COPY config/RustDesk2.toml      /etc/haggai/skel/rustdesk/RustDesk2.toml
COPY config/codex/config.toml   /etc/haggai/skel/codex/config.toml

# Published runtime ports. RustDesk is the remote desktop entrypoint; the web
# ports are for app previews and T3 Code when explicitly started.
EXPOSE 21118/tcp 3000/tcp 3773/tcp 5173/tcp 8080/tcp

WORKDIR /home/user
CMD ["/usr/local/bin/entrypoint.sh"]
