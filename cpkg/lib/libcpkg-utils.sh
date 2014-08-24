PROG=${ME:-"utility"}
PROGTAG="$PROG: "
export CPKG_SPINSTR='|/-\'
export CPKG_CHOICE

function cp_spinner() {
    local TEMP=${CPKG_SPINSTR#?}
    printf " [%c]  " "$CPKG_SPINSTR"
    CPKG_SPINSTR=$TEMP${CPKG_SPINSTR%"$TEMP"}
    printf "\b\b\b\b\b\b"
}

function cp_end_spinner() {
    printf "    \b\b\b\b\n"
}

function cp_clean_name() {
    echo ${1//-/_}
}

function cp_ajoin() {
    local SEP=$1
    shift

    if (($# > 0)); then
        echo -n $1
        shift
    fi

    if (($# > 0)); then
        printf "${SEP}%s" "$@"
    fi
}

function cb_split() {
    local ARR=$1
    local SEP=$2
    local STR=$3

    local IFS=$SEP
    read -ra $ARR <<< "$STR"
}

function cp_copy_hash() {
    local TO=$1
    local FROM=$2
    local KEY

    local -a 'KEYS=("${!'"$FROM"'[@]}")'
    local -a 'VALUES=("${'"$FROM"'[@]}")'
    local I

    for ((I=0; $I < ${#KEYS[@]}; I++)); do
        eval "$TO[\"${KEYS[$I]}\"]=\"${VALUES[$I]}\""
    done
}

function cp_make_save_file() {
    local FILE=$1

    if [[ $FILE =~ ^\+ ]]; then
        # Append mode
        FILE=${FILE#\+}
        mkdir -p $(dirname $FILE)
    else
        # Overwrite
        mkdir -p $(dirname $FILE)
        > $FILE
    fi

    echo $FILE
}

function cp_dump_hash() {
    local -a 'KEYS=("${!'"$1"'[@]}")'
    local -a 'VALUES=("${'"$1"'[@]}")'
    local I

    echo "declare -A $1=("

    for ((I=0; $I < ${#KEYS[@]}; I++)); do
        echo "    [\"${KEYS[$I]}\"]=\"${VALUES[$I]}\""
    done

    echo ")"
}

function cp_dump_list() {
    local ID=$1
    shift

    local AREF="${ID}[@]"

    if (($# == 0)); then
        set -- "${!AREF}"
    fi

    echo "declare -a $ID=("

    if (($# > 0)); then
        echo -n "    "
        cp_ajoin "\n    " "$@"
        echo
    fi

    echo ")"
}

function cp_save_list() {
    local ID=$1
    local FILE=$2
    shift 2

    FILE=$(cp_make_save_file $FILE)
    cp_dump_list $ID "$@" >> $FILE
}

function cp_save_hash() {
    local ID=$1
    local FILE=$2

    FILE=$(cp_make_save_file $FILE)
    cp_dump_hash $ID >> $FILE
}

function cp_file_hash() {
    local FILE=$1

    local HASH=""
    local MD5=""
    local MD5ARGS=""
    local POS=0

    case $CPKG_OS in
        Linux)
        MD5=/usr/bin/md5sum
        POS=1
        ;;

        MacOSX)
        MD5=/usr/pkg/bin/digest
        MD5ARGS=md5
        POS=4
        ;;
    esac

    if [ -e $FILE -a -x $MD5 ]; then
        HASH=$($MD5 $MD5ARGS $FILE 2>/dev/null | cut -d ' ' -f $POS)
    fi

    echo $HASH
}

function cp_run_sed() {
    case $CPKG_OS in
        Linux)
        /usr/bin/sed -r "$@"
        ;;

        MacOSX)
        /usr/bin/sed -E "$@"
        ;;
    esac
}

function cp_run_sedi() {
    case $CPKG_OS in
        Linux)
        /usr/bin/sed -i"" -r "$@"
        ;;

        MacOSX)
        /usr/bin/sed -i "" -E "$@"
        ;;
    esac
}

function cp_reinplace() {
    local EXPR=$1
    shift

    cp_run_sedi -e "$EXPR" "$@"
}

function cp_find_re_rel() {
    local DIR=$1
    local RE=$2

    local FILES

    if [ -d $DIR ]; then
        case $CPKG_OS in
            Linux)
            FILES=$(
                find $DIR \
                    -type f \
                    -regextype posix-extended \
                    -regex "$RE" | xargs
            )
            ;;

            MacOSX)
            FILES=$(find -E $DIR -type f -regex "$RE" | xargs)
            ;;
        esac

        FILES=${FILES//$DIR\/}
    fi

    echo $FILES
}

function cp_find_rel() {
    local DIR=$1

    local FILES

    if [ -d $DIR ]; then
        FILES=$(find $DIR -type f | xargs)
        FILES=${FILES//$DIR\/}
    fi

    echo $FILES
}
