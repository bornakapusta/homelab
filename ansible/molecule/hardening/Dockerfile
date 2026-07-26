# Test image for the hardening role.
#
# systemd runs as PID 1 on purpose. The role's handlers reload sshd through
# `ansible.builtin.systemd`, and stubbing that out would mean the scenario
# tested a different role than the one that runs in production. With real
# systemd, `systemctl reload ssh` and `ufw` both work, so the role runs verbatim.
#
# Requires the container to be started --privileged with the host cgroup fs
# mounted; see create.yml.
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq \
 && apt-get install -y -qq systemd systemd-sysv python3 openssh-server ufw \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Strip the units a container has no business booting; keeps startup quick.
RUN rm -f /lib/systemd/system/multi-user.target.wants/* /etc/systemd/system/*.wants/* \
 && ssh-keygen -A

CMD ["/lib/systemd/systemd"]
