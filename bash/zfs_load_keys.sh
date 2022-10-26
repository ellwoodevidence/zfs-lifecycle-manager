#!/bin/bash

LOGGING=1
SCRIPT_VERSION=0.1

# TODO REMOVE
VAULT_ROLE_ID="<REPLACE ME>"
VAULT_SECRET_ID="<REPLACE ME>"
VAULT_ADDR=https://vault.site.domain


# Helper function, nice logging shortcut
function log () {
    if [[ $LOGGING -eq 1 ]]; then
        echo "$@"
    fi
}


############################################################
# Fetch Vault Token			  							   #
############################################################
log "fetching Vault token"


# Vault Token
VAULT_APPROLE_URL_LOGIN="$VAULT_ADDR/v1/auth/approle/login"
VAULT_APPROLE_JSON=$(jq -n --arg r "$VAULT_ROLE_ID" --arg s "$VAULT_SECRET_ID" '{role_id:$r,secret_id:$s}')
log "VAULT_APPROLE_JSON: $VAULT_APPROLE_JSON"
VAULT_TOKEN_RESPONSE=$(/bin/curl -s -X POST -H Content-type:application/json -d "$VAULT_APPROLE_JSON" "$VAULT_APPROLE_URL_LOGIN")
log "VAULT_TOKEN_RESPONSE: $VAULT_TOKEN_RESPONSE"
VAULT_TOKEN=$(echo $VAULT_TOKEN_RESPONSE | /bin/jq -r .auth.client_token)
log "VAULT_TOKEN: $VAULT_TOKEN"


if [ -z "$VAULT_TOKEN" ]; then
    echo "Error fetching Vault token." | logger
    exit 1
fi

for DATASET_NAME in $(/sbin/zfs list -Ho name,encryptionroot | awk -F "\t" '{ if ($2 != "-") { print $2 }}' | uniq); do
    keylocation=$(/sbin/zfs get -Ho value keylocation "$DATASET_NAME")
	
    keystatus=$(/sbin/zfs get -Ho value keystatus "$DATASET_NAME")
	echo "$DATASET_NAME keystatus: $keystatus"
    if [ "$keylocation" = "prompt" ] && [ "$keystatus" = "unavailable" ]; then
        echo "Loading key for ZFS dataset $DATASET_NAME" | logger
		
		# Check explicit key path
		VAULT_KEY_PATH=$(/sbin/zfs get -Ho value project:vault_key_path "$DATASET_NAME")
		echo "VAULT_KEY_PATH is $VAULT_KEY_PATH"
		VAULT_PATH="$VAULT_KEY_PATH"
		if [ "$VAULT_KEY_PATH" = "-" ]; 
		then
			echo "There is no specific path to the key saved for this dataset. Reconstructing"
			PROJECT_CLIENTCODE=$(/sbin/zfs get -Ho value project:clientcode "$DATASET_NAME")
			PROJECT_SHORTCODE=$(/sbin/zfs get -Ho value project:shortcode "$DATASET_NAME")
			PROJECT_SHORTNAME=$(/sbin/zfs get -Ho value project:shortname "$DATASET_NAME")
			VAULT_PATH="$PROJECT_CLIENTCODE/$PROJECT_SHORTCODE-$PROJECT_SHORTNAME"
			
		else
			echo "Specific VAULT_PATH for secret is $VAULT_KEY_PATH, fetching Vault token."
		fi

		VAULT_PATH_KEY="$VAULT_ADDR/v1/datasets/data/$VAULT_PATH"
				
		echo "Fetching Key from Vault at: $VAULT_PATH_KEY"
        VAULT_KEY=$(/bin/curl -s -H "X-Vault-Token:$VAULT_TOKEN" "$VAULT_PATH_KEY" | /bin/jq -r .data.data.key)
        if [ -n "$VAULT_KEY" ]; then
            echo "$VAULT_KEY" | /sbin/zfs load-key "$DATASET_NAME"
        fi
    fi
done
