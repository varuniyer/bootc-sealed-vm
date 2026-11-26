# Secrets stay unexported shell variables and reach other processes only through
# stdin or /dev/fd paths, never argv, the environment, or local disk.
read_secret() { read -rsp "$1: " "$2"; echo >&2; }
