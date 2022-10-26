# zfs-lifecycle-manager
the zfs-lifecycle-manager allows users to orchestrate zfs dataset encryption, replication and primary write-able locations for datasets saved across multiple distributed systems.

_That is the dream._

## Motivation

We store data for each of our projects under a standard hierarchy.
We can use ZFS user properties to track this information for chargeback and metering. The script also uses this to place the dataset under the correct parent dataset, corresponding to the Client.

> It would be simpler to use mountpoints rather than nested datasets, *but* this would introduce a **security risk**. 
The unprivileged user could create a dataset with an alternate sudoers file and mount over other system dirs.

```
Storage
-> ClientA
--> ProjectCode1
--> ProjectCode3
-> ClientB
--> ProjectCode2
```



## Current Status

The reality at the moment is that we can now:
- [`zfs_create_encrypted_dataset.sh`](bash/zfs_create_encrypted_dataset.sh): creates new encrypted datasets, saving project descriptive metadata to vault.
- [`zfs_load_keys.sh`](bash/zfs_load_keys.sh): Programmatically retrieve the keys from Vault for each encrypted dataset and mount them.

ZFS decryption passphrases are randomly generated and stored per-dataset in Hashicorp Vault.


## Assumptions
We are currently using Octopus as our orchestration / deployment tool. As such, we have limited (non-sudo) users on deployment systems named 'octopus', and commands below reflect this. Change as appropriate.


## Setup

### Setup Vault Secret Store

The expected vault secret store name is: `datasets`.

`vault secrets enable -path=datasets -version=2 kv`

### Setup Deployment User
Create an unprivileged deployment user. We will use the name `octopus`.

`groupadd octopus`
`adduser --ingroup octopus octopus`

#### Allow user to initiate zfs-mount systemd service
We will not grant this user permissions to configure mountpoints, however, they will be able to restart the systemd `zfs-mount` service after creating new datasets.

run `visudo` and add the following line:
`octopus ALL= NOPASSWD: /bin/systemctl restart zfs-mount.service`


### Setup ZFS Dataset Permissions
Create a limited pool which will contain the storage volumes on this storage servier.

`zfs create storage-server/storage/projects`

Only allow the deployment user (in this instance, Octopus) limited rights on the filesystem. For reference, here is documentation on delegated permissions: [zfs-allow.8 — OpenZFS documentation](https://openzfs.github.io/openzfs-docs/man/8/zfs-allow.8.html)

`zfs allow octopus create,load-key,snapshot,encryption,keyformat,keylocation,userprop,compression,readonly storage-server/storage/`

This `octopus` user does not have rights to destroy ZFS datasets.
Note that even though we have allowed `mount` through zfs, the non-sudo user cannot perform mount operations. We got around this earlier by adding the `/bin/systemctl restart zfs-mount.service` command to the sudoers file.

Confirm that you did not over-apply the rights:

```
root@storage-server:~# zfs allow storage-server/storage
---- Permissions on storage-server/storage--------------------------
Local+Descendent permissions:
        user octopus create,load-key,snapshot,encryption,keyformat,keylocation,userprop,compression,readonly
```

You will see that permissions are as you expect.

## Usage

### Create a new Dataset

`./zfs_create_encrypted_dataset.sh -p storage-server/storage -n JustJubbin -c ABC -i ABC12345`

Will create a new dataset like so:

```
octopus@server:~$ ./zfs_create_encrypted_dataset.sh -p storage-server/storage -n "Just Jubbin" -c ABC -i ABC12345
Confirmed that target dataset does not already exist (storage-server/storage/ABC12345-just-jubbin)
Injecting key from Vault into ZFS dataset creation command for 
custom metadata in Vault: {
  "clientcode": "ABC",
  "shortcode": "ABC12345",
  "shortname": "just-jubbin"
}
Key from Vault matches generated key. Save successful.
Creating ZFS Dataset
filesystem successfully created, but it may only be mounted by root
ASSET-ID supplied (), adding as custom user property.
restarting zfs-mount.service
restarted zfs-mount.service
Dataset created and mounted successfully.
```

You can see the resulting dataset properties with:

```
octopus@storage:~$ zfs list -o name,mounted,project:shortcode,project:shortname,project:assetcode storage-server/storage/ABC12345-just-jubbin
NAME                                          MOUNTED  PROJECT:SHORTCODE  PROJECT:SHORTNAME  PROJECT:ASSETCODE
storage-server/storage/ABC12345-just-jubbin  yes      ABC12345           just-jubbin        
```

### Load and Mount Encrypted Datasets

#### For testing, unload a key

Check to see if there are any unmounted datasets.
`zfs list -o name,mounted,keystatus`

You can unmount a test dataset with `zfs unmount` or `umount`.
Then, unload the key with `zfs unload-key storage-server/storage/ABC12345-just-jubbin`.

The key will now be be unavailable:
```
root@storage:~# zfs list -o name,mounted,keystatus storage-server/storage/ABC12345-just-jubbin
NAME                                          MOUNTED  KEYSTATUS
storage-server/storage/ABC12345-just-jubbin  no       unavailable
```

#### Automatically load keys from Vault and mount 

Run the next script: `.\zfs_load_keys.sh`

It will loop over the datasets looking for unavailable keys and fetch them from vault.

```
octopus@TO1-C002-PM002:~$ ./zfs_load_keys.sh fetching Vault token
local-hdd/encrypted keystatus: available
local-nvme/encrypted keystatus: available
storage-server/storage/ABC12345-just-jubbin keystatus: unavailable
VAULT_KEY_PATH is ABC/ABC12345-just-jubbin
Specific VAULT_PATH for secret is ABC/ABC12345-just-jubbin, fetching Vault token.
Fetching Key from Vault at: https://vault.lab.domain/v1/datasets/data/ABC/ABC12345-just-jubbin
storage-server/storage/EEI221015-boop-opening keystatus: available
storage-server/storage/EEI221015-boop-opening2 keystatus: available
storage-server/storage/EEI221015-double-space-plan keystatus: available
storage-server/storage/EEI221015-pauls-transport keystatus: available
storage-server/storage/EEI221015-single-opening keystatus: available
storage-server/storage/EEI221015-single-space keystatus: available
storage-server/storage/EEI221015-tools10 keystatus: available
storage-server/storage/EEI221015-tools11 keystatus: available
storage-server/storage/EEI221015-tools12 keystatus: available
storage-server/storage/EEI221015-tools6 keystatus: available
storage-server/storage/EEI221015-tools9 keystatus: available
storage-server/storage/EEI221015-with-space keystatus: available
storage-server/storage/EEI221015-withoutspaced keystatus: available
storage-server/storage/EEI221026-test19 keystatus: available
storage-server/storage/false-tools7 keystatus: available
storage-server/storage/false-tools8 keystatus: available
```

Voila, your datasets are all unlocked and mounted.

```
zfs list -o name,mounted,project:shortcode,project:shortname,project:assetcode storage-server/storage/ABC12345-just-jubbin
NAME                                          MOUNTED  PROJECT:SHORTCODE  PROJECT:SHORTNAME  PROJECT:ASSETCODE
storage-server/storage/ABC12345-just-jubbin  yes      ABC12345           just-jubbin        
```