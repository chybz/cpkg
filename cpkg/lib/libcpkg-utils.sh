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

function cp_join() {
    local SEP=$1
    shift

    if (($# > 0)); then
        echo -n "$1"
        shift
    fi

    if (($# > 0)); then
        printf "${SEP}%s" "$@"
    fi
}

function cp_indent() {
    local PAD="$1"
    local TEXT="$2"

    echo "$TEXT" | sed -e "s/^/$PAD/g"
}

function cp_split() {
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

    local -a VALUES

    if (($#)); then
        eval 'VALUES=("$@")'
    else
        eval 'VALUES=("${'"$ID"'[@]}")'
    fi

    echo "declare -a $ID=("

    local E

    for E in "${VALUES[@]}"; do
        echo "\"$E\""
    done

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

        Darwin)
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
        /bin/sed -r "$@"
        ;;

        Darwin)
        /usr/bin/sed -E "$@"
        ;;
    esac
}

function cp_run_sedi() {
    case $CPKG_OS in
        Linux)
        /bin/sed -i"" -r "$@"
        ;;

        Darwin)
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
    local TYPE=${3:-f}

    local FILES

    if [ -d $DIR ]; then
        case $CPKG_OS in
            Linux)
            FILES=$(
                find $DIR \
                    -mindepth 1 \
                    -type $TYPE \
                    -regextype posix-extended \
                    -regex "$RE" | xargs
            )
            ;;

            Darwin)
            FILES=$(
                find -E -L $DIR \
                    -mindepth 1 \
                    -type $TYPE \
                    -regex "$RE" | xargs
            )
            ;;
        esac

        FILES=${FILES//$DIR\/}
    fi

    echo $FILES
}

function cp_find_rel() {
    local DIR=$1
    local TYPE=${2:-f}

    local ITEMS

    if [ -d $DIR ]; then
        ITEMS=$(find -L $DIR -mindepth 1 -type $TYPE | xargs)
        ITEMS=${ITEMS//$DIR\/}
    fi

    echo $ITEMS
}
