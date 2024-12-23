#!/bin/bash

# This script helpfully curated via chatgpt attempts to build a huge database for import
# Run it in the context of a fresh project of the correct database type and version
# For bundles, it uses an early version of drupal-cms
# This can be run multiple times, or have the variables changed to create more items.

# Variables
NUM_USERS=100000
NUM_NODES=1000000
NUM_COMMENTED_NODES=1000000
BUNDLES="case_study,page"
DB_EXPORT_PATH=".tarballs/gen.sql.gz"

ddev start

# Enable required modules
echo "Enabling Devel and Devel Generate modules..."
ddev drush pm:enable devel devel_generate -y

# Generate users
echo "Generating $NUM_USERS users..."
ddev drush devel-generate-users $NUM_USERS --roles="authenticated"

# Generate nodes with comments
echo "Generating $NUM_NODES nodes in bundles: $BUNDLES, with $NUM_COMMENTED_NODES nodes having comments..."
ddev drush devel-generate-content --bundles=$BUNDLES $NUM_NODES $NUM_COMMENTED_NODES

# Export the database
echo "Exporting the database to $DB_EXPORT_PATH..."
ddev export-db --file=$DB_EXPORT_PATH

echo "Database export complete: $DB_EXPORT_PATH"
