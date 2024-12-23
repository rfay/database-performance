#!/bin/bash

# For a variety of DDEV versions, a set of db type/version,
# and a set of import files, measure the import time.
# This requires use of /usr/local/bin/ddev and for that to be first found `ddev` in PATH

set -eu -o pipefail

# Configuration variables
ddev_versions="v1.24.1 HEAD" # Space-separated list of ddev versions
database_versions="mysql:8.0"
#database_versions="mysql:8.0 mysql:8.4"
import_files="$HOME/tmp/100k.sql.gz" # Space-separated list of import files
#import_files="$HOME/workspace/database-performance/tarballs/d11.sql.gz $HOME/tmp/100k.sql.gz"
#import_files="$HOME/workspace/database-performance/tarballs/d11.sql.gz"

ddev_binary_path="/usr/local/bin/ddev" # Path to place the ddev binary
docker_platform=$(ddev version -j | jq -r '.raw["docker-platform"]')
basedir=$PWD

# Results file
results_file="${basedir}/import_times_report.${docker_platform}.$(date +'%Y%m%d%H%M%S').csv"
echo "# hostname: $(hostname)" > "$results_file"
echo "ddev_version,database_version,import_file,import_file_size,elapsed_time" >> "$results_file"

# Function to download and install ddev for a specific version
install_ddev() {
  local version=$1
  if [ "$version" == "HEAD" ]; then
    echo "Installing ddev HEAD version..."
    curl -fsSL https://raw.githubusercontent.com/ddev/ddev/refs/heads/master/scripts/install_ddev_head.sh | bash
    head_version=$($ddev_binary_path version | grep "DDEV version" | awk '{print $3}')
    echo "Installed HEAD version: $head_version"
  else
    #echo "Installing ddev version $version..."
    curl -fsSL https://raw.githubusercontent.com/ddev/ddev/master/scripts/install_ddev.sh | bash -s -- "$version"
  fi
}

# Loop through ddev versions and import files
for ddev_version in $ddev_versions; do
  # Install the specified ddev version
#  if [ -f ${ddev_binary_path} ]; then
#    echo "ddev already exists in $ddev_binary_path, please remove it" && exit 1
#  fi
  rm -f ${ddev_binary_path}
  install_ddev $ddev_version

  for database_version in $database_versions; do
    for import_file in $import_files; do
      ddev poweroff
      tmpdesc="${ddev_version}_${database_version}_${import_file}"
      tmpdesc=${tmpdesc//[:\/]/_}
      tmpdir=$HOME/tmp/compare-imports/${tmpdesc}
      mkdir -p ${tmpdir}
#      echo "tmpdir=$tmpdir"
      name=${database_version//:/}
      cd ${tmpdir} && ddev delete -Oy $name && rm -rf .ddev
      ddev config --database=$database_version --project-name="${name}"
      ddev start -y
      echo "Importing $import_file using  $(ddev --version) database $database_version"

      # Measure the time taken for the import
      start_time=$(date +%s)
      ddev import-db --file="$import_file"
      end_time=$(date +%s)

      # Calculate elapsed time
      elapsed_time=$((end_time - start_time))

      # Record the result
      echo "$(ddev --version | awk '{print $3}'),$database_version,$import_file,$(ls -l $import_file | awk '{print $5}'), $elapsed_time" >> "$results_file"
      ddev mysql -e "SELECT (SELECT COUNT(*) FROM users) AS user_count, (SELECT COUNT(*) FROM node) AS node_count;"
      ddev mysql -e 'SELECT table_schema AS database_name, ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS size_mb FROM information_schema.tables WHERE table_schema = "db";'
      ddev delete -Oy && ddev poweroff
    done
  done
done

# Display the results
echo "Import times recorded in $results_file"
rm -f $ddev_binary_path
