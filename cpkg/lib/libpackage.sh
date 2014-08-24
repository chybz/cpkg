if [ -f $ETCDIR/package/$CPKG_TYPE.conf ]; then
    . $ETCDIR/package/$CPKG_TYPE.conf
fi

function lp_create_function() {
    # Create an interface function that must be defined
    # by the underlying package specific library
    local -r F="$1() {
        error \"$1 is not defined for $CPKG_TYPE\"
    }"
    eval "$F"
}

function lp_create_interface() {
    local -a INTERFACE=(
        lp_init
        lp_prepare_package_directory
        lp_handle_manpage
        lp_handle_system_file
        lp_handle_package_files
        lp_install_local_package
        lp_install_packages
        lp_configure_package
        lp_build_package
        lp_make_pkg_map
        lp_make_pkg_header_map
        lp_make_pkgconfig_map
        lp_get_pkgconfig
        lp_find_c_lib
        lp_clean_packages_scripts
    )

    local F

    for F in ${INTERFACE[@]}; do
        lp_create_function $F
    done
}

lp_create_interface

. $CPKG_LIBDIR/$CPKG_TYPE/libpackage.sh

lp_init

function lp_process_package_files() {
    local PHASE
    local CPKG_SCRIPT_BASE

    # Process directories
    # 1. User directories
    # 2. Any directory created by a support module in PKG_BUILDDIR
    for DIR in $PKG_SOURCEDIR $PKG_SUPPORTDIR; do
        # Process templates
        local TEMPLATE_DIR

        for TEMPLATE_DIR in ${!CPKG_TEMPLATE_DIRS[@]}; do
            if [ -d $DIR/$TEMPLATE_DIR ]; then
                mkdir -p ${CPKG_TEMPLATE_DIRS[$TEMPLATE_DIR]}

                # Process .tmpl files
                cp_process_templates \
                    $DIR/$TEMPLATE_DIR \
                    ${CPKG_TEMPLATE_DIRS[$TEMPLATE_DIR]}

                # Copy other files
                $RSYNC \
                    $RSYNC_OPTS $RSYNC_NO_TMPL \
                    $DIR/$TEMPLATE_DIR/ ${CPKG_TEMPLATE_DIRS[$TEMPLATE_DIR]}
            fi
        done

        local OTHER_DIR

        for OTHER_DIR in ${!CPKG_OTHER_DIRS[@]}; do
            if [ -d $DIR/$OTHER_DIR ]; then
                mkdir -p $PKG_STAGEDIR${CPKG_OTHER_DIRS[$OTHER_DIR]}
                $RSYNC \
                    $RSYNC_OPTS \
                    $DIR/$OTHER_DIR/ $PKG_STAGEDIR${CPKG_OTHER_DIRS[$OTHER_DIR]}/
            fi
        done
    done

    # Special processing for utilities/scripts
    if [ -d $PKG_STAGEDIR$PKG_BINDIR ]; then
        CPKG_DIRS=/tmp/cpkg-dirs.$$

        cat > $CPKG_DIRS <<__EOCPKG_DIRS__
ROOTETCDIR=$PKG_SYSETCDIR
ETCDIR=$PKG_ETCDIR
BINDIR=$PKG_BINDIR
ROOTLIBDIR=$PKG_SYSLIBDIR
LIBDIR=$PKG_LIBDIR
ROOTINCDIR=$PKG_SYSINCDIR
INCDIR=$PKG_INCDIR
SHAREDIR=$PKG_SHAREDIR
VARDIR=$PKG_VARDIR
LOGDIR=$PKG_LOGDIR
__EOCPKG_DIRS__

        chmod 755 $PKG_STAGEDIR$PKG_BINDIR/*

        # Trick to keep subst vars intact when self-bootstrapping
        TAG="##"

        # Replace CPKG_DIRS with package generated directories
        for SCRIPT in `grep -l '#!.*sh' $PKG_STAGEDIR$PKG_BINDIR/*`; do
            cp_reinplace "/${TAG}CPKG_DIRS${TAG}/ {
                r $CPKG_DIRS
                d
            }" $SCRIPT
            cp_reinplace "s,^#\!.*bash,#\!$PKG_BINDIR/bash," $SCRIPT
        done

        rm -f $CPKG_DIRS

        # Process inlined POD documentation
        for SCRIPT in `grep -l '=cut' $PKG_STAGEDIR$PKG_BINDIR/*`; do
            MANPAGE=`basename $SCRIPT`
            pod2man $SCRIPT $PKG_ROOTDIR/$MANPAGE.1
            lp_handle_manpage $MANPAGE.1 1
        done
    fi

    # Build manpages
    if [ -d $PKG_SOURCEDIR/pod ]; then
        PODS=`find $PKG_SOURCEDIR/pod -name \*.pod | xargs`

        for POD in $PODS; do
            MANPAGE=`basename $POD .pod`
            pod2man $POD $PKG_ROOTDIR/$MANPAGE
            lp_handle_manpage $MANPAGE $(man_section $MANPAGE)
        done
    fi

    # Prepare package install script
    for PHASE in configure remove purge; do
        if [ -f $PKG_SOURCEDIR/$CPKG_TYPE/$PKG_PARTNAME.$PHASE ]; then
            cp \
                $PKG_SOURCEDIR/$CPKG_TYPE/$PKG_PARTNAME.$PHASE \
                $PKG_ROOTDIR/$PKG_PARTNAME.$PHASE
        fi
    done

    # Copy user-provided system configuration
    local SYSCONF

    for SYSCONF in cron.d init logrotate; do
        if [ -f $PKG_SOURCEDIR/$CPKG_TYPE/$PKG_PARTNAME.$SYSCONF ]; then
            cp \
                $PKG_SOURCEDIR/$CPKG_TYPE/$PKG_PARTNAME.$SYSCONF \
                $PKG_ROOTDIR/$PKG_NAME.$SYSCONF

            lp_handle_system_file \
                $PKG_ROOTDIR/$PKG_NAME.$SYSCONF \
                $SYSCONF
        fi
    done

    lp_handle_package_files
}
