# TODOs

- When trying to start `rpc.nfsd`, it fails with:

  ```
  rpc.nfsd: Unable to access /proc/fs/nfsd errno 2 (No such file or directory).
  Please try, as root, 'mount -t nfsd nfsd /proc/fs/nfsd' and then restart rpc.nfsd to correct the problem
  ```
  
  This is because the host's kernel doesn't include the `nfsd` kernel module and hence the container can't load that module.
  
  Next steps: Figure out how to build our own HAOS images and enable the `nfsd` module for them. If it works, suggest to include it upstream in the [Home Assistant OS repo](https://github.com/home-assistant/operating-system).

- We currently set `full_access: true` for testing. Instead, we should granulary grant the actually necessary [capabilities](https://docs.docker.com/engine/containers/run/#runtime-privilege-and-linux-capabilities) via the `privileged` key.

- We currently set `apparmor: false` to fully disable [AppArmor](https://developers.home-assistant.io/docs/apps/presentation/#apparmor) for testing. Instead, we should try `apparmor: true` with HA's default profile (i.e. removing our custom `apparmor.txt` file, or replacing it with the default one, not sure). If that works, try to improve on the default profile. If not, try starting from our current custom profile (likely only works with a lot more relaxed restrictions).
