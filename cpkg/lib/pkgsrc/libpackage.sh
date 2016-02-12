##############################################################################
#
# pkgsrc+pkgin specific package building
#
##############################################################################
function lp_init() {
    [ -z "$PKGSRC_DIR" ] && cp_error "PKGSRC_DIR is not configured"
    [ -e "$PKGSRC_DIR" -a -f "$PKGSRC_DIR/mk/bsd.pkg.mk" ] || \
        cp_error "$PKGSRC_DIR is not a valid pkgsrc source directory"

    export PKGSRC_DIR
}

function lp_prepare_package_directory() {
    return
}

function lp_handle_manpage() {
    local MANPAGE=$1
    local MANSECT=$2
    local MANDIR=$PKG_STAGEDIR/$PKG_MANDIR/man$MANSECT

    mkdir -p $MANDIR
    mv $PKG_ROOTDIR/$MANPAGE $MANDIR
}

function lp_handle_system_file() {
    local FILE=$1
    local TYPE=$2

    return
}

function lp_handle_package_files() {
    # pkgsrc wants etc/ to be handled via it CONF_FILES framework

    if [[ -d $PKG_STAGEDIR/$PKG_SYSETCDIR ]]; then
        mkdir -p $PKG_STAGEDIR/$PKG_SHAREDIR
        [[ -d $PKG_STAGEDIR/$PKG_SHAREDIR/etc ]] && \
            rm -rf $PKG_STAGEDIR/$PKG_SHAREDIR/etc
        mv $PKG_STAGEDIR/$PKG_SYSETCDIR $PKG_STAGEDIR/$PKG_SHAREDIR/etc
    fi
}

function lp_clean_packages_scripts() {
    return
}

function lp_install_local_package() {
    local DIR=$PKGSRC_DIR/packages/All

    [[ -d "$DIR" ]] || cp_error "invalid binary package directory: $DIR"

    local PKG=$DIR/${PKG_NAME}-${PKG_VER}.tgz

    [[ -f "$PKG" ]] || cp_error "package not found: $PKG"
    sudo pkg_add -U $PKG
    sudo pkgin -f ls >/dev/null
}

function lp_install_packages() {
    sudo pkgin install $@
    lp_make_pkg_map
}

function lp_configure_package() {
    if (($PKG_UPDATE)); then
        if cp_has_uncommitted_changes; then
            cp_error "cannot update with uncommited changes"
        fi
    fi
}

function lp_build_package() {
    local DIR=$PKGSRC_DIR/$PKG_CAT/$PKG_NAME

    [[ -d "$DIR" ]] || cp_error "invalid package directory: $DIR"

    cd $DIR

    sudo bmake distclean
    sudo bmake fetch
    sudo bmake mdi
    sudo bmake
    sudo bmake stage-install CHECK_FILES=no
    sudo bmake print-PLIST > PLIST
    sudo bmake install-clean
    pkglint
    sudo bmake package
}

function lp_make_pkg_map() {
    cp_make_home

    local CACHE=$CPKG_HOME/packages.cache

    rm -f $CACHE

    pkg_info -a | \
    sed \
        -E \
        -e "s,-[[:digit:]].*$, 1,g" | \
        cdb -c -m $CACHE
}

function make_pkg_providers_cache() {
    local DIR=$1
    local CACHE=$2
    local EXPR=$3

    local PKG

    pkg_info -aL | \
        egrep "^Information|$DIR/$EXPR" | \
        sed \
            -E \
            -e "s,$DIR/,,g" \
            -e "s,Information for (.*)-[[:digit:]].*,PACKAGE \1,g" \
        > $CACHE.tmp

    while read LINE; do
        if [[ "$LINE" =~ ^PACKAGE[[:space:]]+(.*)$ ]]; then
            PKG="${BASH_REMATCH[1]}"
        else
            echo "$LINE $PKG"
        fi
    done < $CACHE.tmp > $CACHE

    rm -f $CACHE.tmp
}

function build_pkgconfig_filters() {
    local CACHE=$1

    cp_msg "building pkg-config header filters"

    set +e

    find $CPKG_PREFIX/lib/pkgconfig -name \*.pc | while read PC; do
        pkg-config \
            --cflags-only-I \
            --silence-errors \
            $(basename $PC .pc) | \
        sed \
            -e "s/-I//g" \
            -e 's/ /\'$'\n/g' | \
        grep -v "^$"
    done | sort | uniq | \
    sed -E -e "s,/$,," | \
    grep -v "^$CPKG_PREFIX/include$" | \
    sed \
        -E \
        -e "s,^$CPKG_PREFIX/(include|lib)/,s@^," \
        -e "s,^/opt/X11/(include|lib)/,s@^," \
        -e "s,$,/@@," \
        > $CACHE.filters

    set -e
}

function build_header_cache() {
    local CACHE=$1
    local CACHENAME=$2

    build_pkgconfig_filters $CACHE

    cp_msg "building pkgsrc header cache"

    find $PKGSRC_DIR/ -type f -name PLIST | \
        xargs grep "^include/" | \
        sed \
            -E \
            -e "s,^.*/(.*)/PLIST:include/(.*)$,\2 \1,g" \
            -f $CACHE.filters \
        > $CACHE.uninstalled

    make_pkg_providers_cache "$CPKG_PREFIX/include" $CACHE.installed.tmp ".*\.h.*" 1
    sed -E -f $CACHE.filters < $CACHE.installed.tmp > $CACHE.installed
    rm -f $CACHE.installed.tmp

    cat $CACHE.uninstalled $CACHE.installed | \
        sort | uniq | \
        cdb -c -m $CACHE

    rm -f $CACHE.uninstalled $CACHE.installed
}

function lp_make_pkg_header_map() {
    cp_make_home

    local CACHE=$CPKG_HOME/headers.cache
    local REFFILE=/var/db/pkgin/pkgin.db
    local BUILD=0

    if [ ! -f $CACHE ]; then
        BUILD=1
    elif [ $REFFILE -nt $CACHE ]; then
        BUILD=1
    fi

    if (($BUILD == 1)); then
        build_header_cache $CACHE "CPKG_HEADER_MAP"
    fi
}

function build_pkgconfig_cache() {
    local CACHE=$1

    cp_msg "building pkgsrc pkg-config cache"

    pkg_info -aL | \
        egrep "^Information|$CPKG_PREFIX/lib/pkgconfig/.*\.pc" | \
        sed \
            -E \
            -e "s,$CPKG_PREFIX/lib/pkgconfig/,,g" \
            -e "s,\.pc,,g" \
            -e "s,Information for (.*)-[[:digit:]].*,PACKAGE \1,g" \
        > $CACHE.info

    while read LINE; do
        if [[ "$LINE" =~ ^PACKAGE[[:space:]]+(.*)$ ]]; then
            PKG="${BASH_REMATCH[1]}"
        else
            echo "$PKG $LINE"
        fi
    done < $CACHE.info > $CACHE.tmp

    rm -f $CACHE.info

    local PC
    local PKG
    local -A MAP

    while read PKG PC; do
        PC=${PC%.pc}

        if [[ "${MAP[$PKG]}" ]]; then
            MAP[$PKG]+=" $PC"
        else
            MAP[$PKG]=$PC
        fi
    done < $CACHE.tmp

    rm -f $CACHE.tmp

    for PKG in ${!MAP[@]}; do
        echo "$PKG ${MAP[$PKG]}"
    done | cdb -c -m $CACHE
}

function lp_make_pkgconfig_map() {
    cp_make_home

    local CACHE=$CPKG_HOME/pkgconfig.cache
    local REFFILES="/var/db/pkgin/pkgin.db /var/db/pkg/pkgdb.byfile.db"
    local REFFILE
    local BUILD=0

    if [ ! -f $CACHE ]; then
        BUILD=1
    else
        for REFFILE in $REFFILES; do
            if [ $REFFILE -nt $CACHE ]; then
                BUILD=1
                break
            fi
        done
    fi

    if (($BUILD == 1)); then
        build_pkgconfig_cache $CACHE
    fi
}

function lp_get_pkgconfig() {
    local PC=$1
    shift

    local PCPATH=$PKG_CONFIG_PATH

    if [ -n "$PCPATH" ]; then
        PCPATH+=":$CPKG_PREFIX/lib/pkgconfig"
    else
        PCPATH="$CPKG_PREFIX/lib/pkgconfig"
    fi

    env PKG_CONFIG_PATH=$PCPATH pkg-config $@ $PC
}

function lp_full_pkg_name() {
    local PKG=$1

    local FULLPKG=$(
        sqlite3 \
            /var/db/pkgin/pkgin.db \
            "select FULLPKGNAME from [REMOTE_PKG] where PKGNAME='$PKG'"
    )

    [[ -n "$FULLPKG" ]] || FULLPKG=$PKG

    echo $FULLPKG
}
