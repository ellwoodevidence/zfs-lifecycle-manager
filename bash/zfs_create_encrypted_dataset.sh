#!/bin/bash


############################################################
# Help  Text                                               #
############################################################
Help()
{
   # Display Help
   echo "Create a new encrypted dataset, storing the key" 
   echo "in Hashicorp Vault."
   echo
   echo "Prerequisites: jq, zfs"
   echo
   echo "This script requires that the user running it"
   echo "has been delegated specific dataset permissions on"
   echo "the parent dataset which will hold the newly created"
   echo "dataset. These permissions are:"
   echo "       mount,create,load-key,snapshot,encryption,"
   echo "       keyformat,keylocation,userprop,compression,readonly"
   echo 
   echo "Mount Requirements:"
   echo "If you are running as a user that does not have mount"
   echo "rights on this system, then you must have the ability"
   echo "to restart the $(zfs-mount) system service."
   echo "This can be granted by adding the following to your sudoers file:"
   echo
   echo "       octopus ALL= NOPASSWD: /bin/systemctl restart zfs-mount.service"
   echo
   echo "Syntax: zfs_create_encrypted_dataset -p <DATASET_PARENT>"
   echo "options:"
   echo "h                      Print this Help."
   echo "p                      Parent Dataset Name (e.g. local-hdd/encrypted/storage/cases)"
   echo "i                      Project ShortCode id ( e.g. ABC210101)"
   echo "c                      Project ClientCode ( e.g. ABC)"
   echo "n                      Project ShortName ( e.g. 'Johnson Apples')"
   echo "a                  Project Dataset Asset ID (optional)."
   echo "v                      verbose mode (WARNING, prints secrets to console)"
   echo "V                  Print software version and exit."


}

LOGGING=0
SCRIPT_VERSION=0.1


# Helper function, nice logging shortcut
function log () {
    if [[ $LOGGING -eq 1 ]]; then
        echo "$@"
    fi
}

############################################################
############################################################
# Main Program: Create New Encrypted Dataset                   #
############################################################
############################################################

# Environment Paths
zfs_bin=/usr/sbin/zfs

# Dataset Creation Variables
DATASET_PARENT=false
DATASET_ENCRYPTION_ALGO="aes-256-gcm"

#PROJECT_SHORTCODE=false
#PROJECT_CLIENTCODE=false
#PROJECT_SHORTNAME=false

DATASET_MOUNT_PAUSE=1

DEFAULT_OWNER=434400500
DEFAULT_GROUP=434412651

# set in environment vars
#VAULT_ROLE_ID=""
#VAULT_SECRET_ID=""
VAULT_ADDR=https://vault.example.com

# Secret Storage and Deployment Options
VAULT_APPROLE_URL_LOGIN="$VAULT_ADDR/v1/auth/approle/login"

OCTOPUS_OUTVARS=false




############################################################
# Process the input options.                                                   #
############################################################
# Get the options

while getopts ":hp:i:c:n:ovVa:" option; do
   case $option in
      h) # display Help
         Help
         exit;;
          p) # set parent dataset variable
         DATASET_PARENT=$OPTARG;;
          i) # set parent dataset variable
         PROJECT_SHORTCODE=$OPTARG;;
          c) # set parent dataset variable
         PROJECT_CLIENTCODE=$OPTARG;;
          n) # set parent dataset variable
         PROJECT_SHORTNAME=$OPTARG;;
          a) # set Asset ID for inventory tracking
         PROJECT_ASSETID=$OPTARG
                 echo "parsed assets id"
                 ;;
          o) # output Octopus setvars for later runbook steps
         OCTOPUS_OUTVARS=true;;
          v) # Verbose logging
         LOGGING=1;;
          V) # Script Version
         echo "ZFS Encrypted Dataset Creation Script, version $SCRIPT_VERSION"
                 exit;;
         \?) # Invalid option
         echo "Error: Invalid option: $option"
                 echo "Run with the -h flag for help text."
         exit 2;;
   esac
done

log "Completed parsing arguments"

############################################################
# Check that required variables are populated                      #
# TODO                                                                                                     #
############################################################



############################################################
# Fetch Vault Token                                                                                #
############################################################
log "fetching Vault token"

# Vault Token
VAULT_APPROLE_JSON=$(jq -n --arg r "$VAULT_ROLE_ID" --arg s "$VAULT_SECRET_ID" '{role_id:$r,secret_id:$s}')
log "VAULT_APPROLE_JSON: $VAULT_APPROLE_JSON"
VAULT_TOKEN_RESPONSE=$(/bin/curl -s -X POST -H Content-type:application/json -d "$VAULT_APPROLE_JSON" "$VAULT_APPROLE_URL_LOGIN")
log "VAULT_TOKEN_RESPONSE: $VAULT_TOKEN_RESPONSE"
VAULT_TOKEN=$(echo "$VAULT_TOKEN_RESPONSE" | /bin/jq -r .auth.client_token)
log "VAULT_TOKEN: $VAULT_TOKEN"


if [ -z "$VAULT_TOKEN" ]; then
    echo "Error fetching Vault token." | logger
    exit 1
fi

log "fetched Vault token, $VAULT_TOKEN"

############################################################
# Confirm Dataset does not already exist                           #
############################################################

log "Check that the $DATASET_PARENT exists"

DATASET_PARENT_EXIST=$($zfs_bin list -Ho name,used "$DATASET_PATH" 2>&1)
DATASET_PARENT_DOES_NOT_EXIST=${DATASET_PARENT_EXIST: -22}
if [ "$DATASET_PARENT_DOES_NOT_EXIST" = "dataset does not exist" ]; then
        echo "Error - Intended Parent does not exist: $DATASET_PARENT_EXIST" | logger
    exit 1
fi


# Slugify
  # Transliterate everything to ASCII
  # Strip out apostrophes
  # Anything that's not a letter or number to a dash
  # Strip leading & trailing dashes
  # Everything to lowercase
function slugify() {
  iconv -t ascii//TRANSLIT \
  | tr -d "'" \
  | sed -E 's/[^a-zA-Z0-9]+/-/g' \
  | sed -E 's/^-+|-+$//g' \
  | tr "[:upper:]" "[:lower:]"
}

PROJECT_SHORTNAME_SLUG=$(echo "$PROJECT_SHORTNAME" | slugify)
DATASET_NAME="$PROJECT_SHORTCODE-$PROJECT_SHORTNAME_SLUG"

log "Set Dataset Name: $DATASET_NAME"

DATASET_PATH_CLIENT="$DATASET_PARENT/$PROJECT_CLIENTCODE"
DATASET_PATH="$DATASET_PARENT/$PROJECT_CLIENTCODE/$DATASET_NAME"

# Check that the parent dataset already exists
CHECK_EXIST_CLIENT=$($zfs_bin list -Ho name,used "$DATASET_PATH_CLIENT" 2>&1)
DOES_NOT_EXIST_PARENT=${CHECK_EXIST_CLIENT: -22}
if [ "$DOES_NOT_EXIST_PARENT" = "dataset does not exist" ]; then
    echo "Planned Project Dataset does not exist, must create: $CHECK_EXIST_CLIENT"
    CREATE_CLIENT=true
else
    echo "Confirmed that parent dataset already exists: ($DATASET_PATH_CLIENT)"
    CREATE_CLIENT=false
fi




# Check that dataset does not already exist
CHECK_EXIST=$($zfs_bin list -Ho name,used "$DATASET_PATH" 2>&1)
DOES_NOT_EXIST=${CHECK_EXIST: -22}
if [ "$DOES_NOT_EXIST" != "dataset does not exist" ]; then
        echo "Error - Planned Dataset already exists: $CHECK_EXIST"
    exit 1
fi

echo "Confirmed that target dataset does not already exist ($DATASET_PATH)"


############################################################
# Create Vault Secret                                                                      #
############################################################

DATASET_ENCRYPTION_PASSPHRASE=$(openssl rand -base64 18)
log "Created Dataset Encryption Passphrase: $DATASET_ENCRYPTION_PASSPHRASE"


JSON_DATA=$( jq -c -n \
                  --arg key "$DATASET_ENCRYPTION_PASSPHRASE" \
                  '{key: $key}' 
                                  )
log "created JSON_DATA: $JSON_DATA"


JSON_CUSTOM_METADATA=$( jq -c -n \
                  --arg shortcode "$PROJECT_SHORTCODE" \
                                  --arg clientcode "$PROJECT_CLIENTCODE" \
                                  --arg shortname "$PROJECT_SHORTNAME_SLUG" \
                  '{shortcode: $shortcode, clientcode: $clientcode, shortname: $shortname}' 
                                  )
log "created JSON_CUSTOM_METADATA: $JSON_CUSTOM_METADATA"


VAULT_UPLOAD_SECRET="{\"data\":${JSON_DATA},\"options\":{\"cas\": 0}}"
log "Created Vault Upload Secret json blob: $VAULT_UPLOAD_SECRET"

############################################################
# Upload Encryption Key to Vault                                                   #
############################################################
# The HTTPS API format here is $VAULT_ADDR/v1/<KV ENGINE>/data/<PATH TO SECRET>
# See Further: https://www.vaultproject.io/api-docs/secret/kv/kv-v2

VAULT_PATH_KEY="$VAULT_ADDR/v1/datasets/data/$PROJECT_CLIENTCODE/$DATASET_NAME"

VAULT_UPLOAD_RESULT=$(curl -s -H "X-Vault-Token:$VAULT_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST -d "$VAULT_UPLOAD_SECRET" \
        "$VAULT_PATH_KEY")

log "Got this response from Vault: $VAULT_UPLOAD_RESULT"

# TODO THIS BREAKS THINGS
log "Did we already see an existing key?"
#PREEXISTING_KEY=$(/bin/curl -s -H "X-Vault-Token:$VAULT_TOKEN" "$VAULT_PATH_KEY" | /bin/jq -r .data.data.metadata)
PREEXISTING_KEY=$(/bin/curl -s -H "X-Vault-Token:$VAULT_TOKEN" "$VAULT_PATH_KEY")
log "Got the following: $PREEXISTING_KEY"

if [ -z "$PREEXISTING_KEY" ]; then

    echo "Error: Dataset Encryption Key Already Exists"
        log "Blowing up the process because PREEXISTING_KEY is: $PREEXISTING_KEY"
    exit 1
fi


############################################################
# Update Secret Custom Metadata                                                    #
############################################################

log "creating custom metatada in Vault"
VAULT_METADATA_PATH_KEY="$VAULT_ADDR/v1/datasets/metadata/$PROJECT_CLIENTCODE/$DATASET_NAME"
VAULT_METADATA_UPLOAD="{\"custom_metadata\":$JSON_CUSTOM_METADATA,\"options\":{\"cas\": 0}}"

log "uploading this blob of VAULT_METADATA_UPLOAD: $VAULT_METADATA_UPLOAD"

VAULT_METADATA_UPLOAD_RESULT=$(curl -s -H "X-Vault-Token:$VAULT_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST -d "$VAULT_METADATA_UPLOAD" \
        "$VAULT_METADATA_PATH_KEY")

log "(1) Got this response from Vault: $VAULT_METADATA_UPLOAD_RESULT"


############################################################
# Retrieve Encryption Key and Metadata from Vault          #
############################################################

# Get Encryption Key
echo "Injecting key from Vault into ZFS dataset creation command for $DATASET_PATH"
VAULT_DATASET_ENCRYPTION_KEY=$(/bin/curl -s -H "X-Vault-Token:$VAULT_TOKEN" "$VAULT_PATH_KEY" | /bin/jq -r .data.data.key)

# Get Metadata
VAULT_DATASET_METADATA=$(/bin/curl -s -H "X-Vault-Token:$VAULT_TOKEN" "$VAULT_METADATA_PATH_KEY" | /bin/jq -r .data.custom_metadata)
echo "custom metadata in Vault: $VAULT_DATASET_METADATA"

# Confirm Stored Encryption Key

if [ "$VAULT_DATASET_ENCRYPTION_KEY" != "$DATASET_ENCRYPTION_PASSPHRASE" ]; then
    echo "The Encryption Key in Vault does not match the one which was generated earlier."
        log "Encryption Key Generated: $DATASET_ENCRYPTION_PASSPHRASE"
        log "Encryption key from Vault: $VAULT_DATASET_ENCRYPTION_KEY"
        exit 1
else
        echo "Key from Vault matches generated key. Save successful."

fi



#################################################
# Create the Client Dataset (if required)       #
#################################################
if [ "$CREATE_CLIENT" = true ]; then
    echo "Creating Client ZFS Dataset"

    $zfs_bin create \
        -o compression=on \
        -P \
        "$DATASET_PATH_CLIENT"

    # Confirm mount was successful
    # Check that dataset does not already exist
    CHECK_MOUNTED_CLIENT=$($zfs_bin list -Ho mounted,mountpoint "$DATASET_PATH_CLIENT" 2>&1)
    log "CHECK_MOUNTED is: $CHECK_MOUNTED_CLIENT"
    if [ "$(echo "$CHECK_MOUNTED_CLIENT" | cut -f1)" = "yes" ]; 
            then
                echo "Client Dataset created and mounted successfully."
            else
                echo "Warning: the Client Dataset was created, but was not mounted."
                #################################################
                # Mount the Client dataset                      #
                #################################################
                # This requires the following to be added to the system's sudoers file:
                #       octopus ALL= NOPASSWD: /bin/systemctl restart zfs-mount.service

                echo "restarting zfs-mount.service"
                sudo systemctl restart zfs-mount.service
                echo "restarted zfs-mount.service"
                echo "waiting for $DATASET_MOUNT_PAUSE seconds."
                sleep $DATASET_MOUNT_PAUSE
    fi

    # check again
    CHECK_MOUNTED_CLIENT=$($zfs_bin list -Ho mounted,mountpoint "$DATASET_PATH_CLIENT" 2>&1)
    log "CHECK_MOUNTED is: $CHECK_MOUNTED_CLIENT"

    if [ "$(echo "$CHECK_MOUNTED_CLIENT" | cut -f1)" = "yes" ]; 
            then
                echo "Client Dataset created and mounted successfully."

                echo "Running permissions update across: $(echo "$CHECK_MOUNTED_CLIENT" | cut -f2)"
                sudo setfacl -R --set-file acl_template.txt "$(echo "$CHECK_MOUNTED_CLIENT" | cut -f2)"
                sudo /usr/bin/chown -R "$DEFAULT_OWNER":"$DEFAULT_GROUP" "$(echo "$CHECK_MOUNTED_CLIENT" | cut -f2)"
            
            else
                echo "Error: the Client Dataset was created, but was not mounted after $DATASET_MOUNT_PAUSE seconds."
                exit 1
    fi
fi


#################################################
# Create the Project Dataset                    #
#################################################

echo "Creating Project ZFS Dataset"

if [ -n "$VAULT_DATASET_ENCRYPTION_KEY" ]; then
        echo "$VAULT_DATASET_ENCRYPTION_KEY" | $zfs_bin create \
        -o keyformat=passphrase \
        -o compression=on \
        -P \
        -o "encryption=$DATASET_ENCRYPTION_ALGO" \
        "$DATASET_PATH"

        #

        # userprop can only be delegated modify, not on creation:
        $zfs_bin set "project:shortcode=$PROJECT_SHORTCODE" "$DATASET_PATH"
        $zfs_bin set "project:clientcode=$PROJECT_CLIENTCODE" "$DATASET_PATH"
        $zfs_bin set "project:shortname=$PROJECT_SHORTNAME_SLUG" "$DATASET_PATH"
        $zfs_bin set "project:vault_key_path=$PROJECT_CLIENTCODE/$DATASET_NAME" "$DATASET_PATH"

        if [ -n "$PROJECT_ASSETID" ]
        then
                log "No ASSETS-ID specified."
        else
                echo "ASSET-ID supplied ($PROJECT_ASSETID), adding as custom user property."
                $zfs_bin set "project:assetcode=$PROJECT_ASSETID" "$DATASET_PATH"
        fi
fi


#################################################
# Mount the Dataset                             #
#################################################
# This requires the following to be added to the system's sudoers file:
#       octopus ALL= NOPASSWD: /bin/systemctl restart zfs-mount.service

echo "restarting zfs-mount.service"
sudo systemctl restart zfs-mount.service
echo "restarted zfs-mount.service"


# Confirm mount was successful
# Check that dataset does not already exist
CHECK_MOUNTED=$($zfs_bin list -Ho mounted,mountpoint "$DATASET_PATH" 2>&1)
log "CHECK_MOUNTED is: $CHECK_MOUNTED"
if [ "$(echo "$CHECK_MOUNTED" | cut -f1)" = "yes" ]; 
        then
                echo "Dataset created and mounted successfully."

                echo "Running permissions update across: $(echo "$CHECK_MOUNTED" | cut -f2)"
                sudo setfacl -R --set-file acl_template.txt "$(echo "$CHECK_MOUNTED" | cut -f2)"
                sudo /usr/bin/chown -R "$DEFAULT_OWNER":"$DEFAULT_GROUP" "$(echo "$CHECK_MOUNTED" | cut -f2)"
        else
                echo "Error: the Dataset was created, but was not mounted."
                exit 1
fi



# Upload ZFS Dataset GUID to VAULT_ADDR



#################################################
# References                                    #
#################################################
# Options handling inspired by:
# https://www.redhat.com/sysadmin/arguments-options-bash-scripts
# Slugify from:
# https://duncanlock.net/blog/2021/06/15/good-simple-bash-slugify-function
#