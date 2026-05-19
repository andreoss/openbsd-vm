#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use File::Copy;
use Cwd;
use POSIX qw(strftime);

our $WORK   = getcwd();
our $LOG    = "$WORK/openbsd.mlog";
our $PIDF   = "$WORK/ovmf.pid";
our $SERLOG = "$WORK/serial.mlog";

our $IMG_INSTALL = "$WORK/install79.img";
our $IMG_SYSTEM  = "$WORK/system.img";
our $OVMF        = "$WORK/OVMF.fd";
our $SSHKEY      = "$WORK/vmkey";
our $KNOWN_HOSTS = "$WORK/known_hosts";

our $ROOT_PW = 'toor';
our $HOST    = 'puffy';
our $DOMAIN  = 'cx';
our $USER    = 'a';
our $GROUP   = 'staff';
our $UID     = 1337;
our $TZ      = 'America/New_York';
our $GOP     = 15;
our $SSH_PORT  = 22;
our $SSH_HOST  = '';
our $IPFILE    = "$WORK/guest.ip";
our $FW_PORT   = 7922;
our $MON_PORT  = 1233;
our $SER_PORT  = 1234;
our $MEM       = '4g';
our $SMP       = 3;

our $PUBKEY = '';
our $DEBUG  = 1;

sub mlog {
    my ($msg) = @_;
    my $ts = strftime('%Y-%m-%d %H:%M:%S', localtime);
    open(my $fh, '>>', $LOG) or die "mlog: $!\n";
    print $fh "$ts $msg\n";
    close $fh;
    print "[$ts] $msg\n" if $DEBUG;
}

sub dolog {
    my ($raw) = @_;
    open(my $fh, '>>', $SERLOG) or return;
    print $fh $raw;
    close $fh;
}

sub run {
    my (@cmd) = @_;
    mlog "cmd: @cmd";
    my $out = `@cmd 2>&1`;
    my $rc  = $? >> 8;
    mlog "rc=$rc out=" . substr($out, 0, 3000) if $out;
    return ($rc, $out);
}

sub connect_tcp {
    my ($port, $tries) = @_;
    $tries //= 60;
    for (1 .. $tries) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp',
            Timeout  => 2, Blocking => 1,
        );
        return $sock if $sock;
        sleep 1;
    }
    return undef;
}

sub clean {
    my ($b) = @_;
    my $out = '';
    my $i   = 0;
    my $n   = length $b;
    while ($i < $n) {
        my $c = substr($b, $i, 1);
        if (ord($c) == 255) {
            $i += 3;
            next;
        }
        $out .= $c;
        $i++;
    }
    return $out;
}

our $BUF = '';
our $GOT = '';

sub expect {
    my ($s, $timeout, @want) = @_;
    my $dead = time + $timeout;
    my $sel  = IO::Select->new($s);
    while (1) {
        for my $i (0 .. $#want) {
            my $re  = $want[$i];
            my $ok  = eval { $BUF =~ $re ? 1 : 0 };
            if ($ok) {
                mlog "got[$i] tail=" . substr($BUF, -80);
                $GOT = $BUF;
                $BUF = '';
                return ($i);
            }
        }
        my $left = $dead - time;
        last if $left <= 0;
        my @r = $sel->can_read($left);
        if (@r) {
            my $ch = '';
            my $n  = sysread($s, $ch, 16384);
            if (!defined($n) || $n == 0) {
                mlog "serial closed";
                last;
            }
            my $c = clean($ch);
            $BUF .= $c;
            dolog($c);
        }
    }
    mlog "timeout($timeout) tail=" . substr($BUF, -200);
    return (-1);
}

sub tx {
    my ($s, $data) = @_;
    my $esc = $data;
    $esc =~ s/\r/\\r/g;
    $esc =~ s/\n/\\n/g;
    mlog ">> $esc";
    syswrite($s, $data);
}

sub txh {
    my ($s, $data) = @_;
    for (split //, $data) {
        syswrite($s, $_);
        select undef, undef, undef, 0.02 + rand(0.05);
    }
}

sub wait_port {
    my ($port) = @_;
    return connect_tcp($port);
}

sub read_pubkey {
    open(my $fh, '<', "$SSHKEY.pub") or return '';
    $PUBKEY = <$fh>;
    chomp $PUBKEY;
    close $fh;
    return $PUBKEY;
}

sub shq {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub net_mode {
    return 'bridge' if glob('/sys/class/net/virbr*');
    return 'user';
}

sub prep {
    mlog "=== PREP ===";
    unless (-f $IMG_INSTALL) {
        my $url = 'https://cdn.openbsd.org/pub/OpenBSD/7.9/amd64/install79.img';
        mlog "downloading $url";
        run('curl', '-fLo', $IMG_INSTALL, $url) or die "download install: $?\n";
    }
    unless (-f $OVMF) {
        for my $cand (glob('/nix/store/*-OVMF*/FV/OVMF.fd'), glob('/usr/share/OVMF/OVMF.fd'), glob('/usr/share/ovmf/OVMF.fd')) {
            next unless -f $cand;
            mlog "copying ovmf from $cand";
            run('cp', '-f', $cand, $OVMF);
            last;
        }
    }
    unless (-f $OVMF) {
        my $url = 'https://raw.githubusercontent.com/retrage/edk2-nightly/master/bin/RELEASEX64_OVMF.fd';
        mlog "downloading $url";
        run('curl', '-fLo', $OVMF, $url) or die "download ovmf: $?\n";
    }
    die "ovmf missing: $OVMF\n" unless -f $OVMF;
    my ($rc, $out) = run('test', '-f', $IMG_SYSTEM);
    if ($rc != 0) {
        run('qemu-img', 'create', '-f', 'raw', $IMG_SYSTEM, '16005464064');
    }
    unless (-f $SSHKEY) {
        run("ssh-keygen -t ed25519 -N '' -C openbsd-vm -f $SSHKEY");
    }
    read_pubkey() or die "no pubkey\n";
}

sub qemu_args {
    my ($install) = @_;
    my @a;
    push @a, 'qemu-system-x86_64';
    push @a, '-accel', 'kvm';
    push @a, '-accel', 'tcg';
    push @a, '-cpu', 'max';
    push @a, '-smp', $SMP;
    push @a, '-m', $MEM;
    push @a, '-bios', $OVMF;
    push @a, '-device', 'virtio-scsi-pci,id=scsi';
    push @a, '-device', 'scsi-hd,drive=hd0';
    push @a, '-drive', "file=$IMG_SYSTEM,media=disk,format=raw,if=none,id=hd0";
    push @a, '-drive', "file=$IMG_INSTALL,media=disk,format=raw" if $install;
    if (net_mode() eq 'bridge') {
        push @a, '-netdev', 'bridge,id=mn0,br=virbr0,helper=/run/wrappers/bin/qemu-bridge-helper';
    } else {
        push @a, '-netdev', "user,id=mn0,hostfwd=tcp:127.0.0.1:$FW_PORT-:22";
    }
    push @a, '-device', 'virtio-net,netdev=mn0';
    push @a, '-chardev', "socket,id=ser0,server=on,wait=off,telnet=on,port=$SER_PORT,host=127.0.0.1,ipv4=on,ipv6=off";
    push @a, '-serial', 'chardev:ser0';
    push @a, '-chardev', "socket,id=mon0,server=on,wait=off,telnet=on,port=$MON_PORT,host=127.0.0.1,ipv4=on,ipv6=off";
    push @a, '-monitor', 'chardev:mon0';
    push @a, '-display', 'none';
    push @a, '-vga', 'virtio';
    push @a, '-pidfile', $PIDF;
    push @a, '-daemonize';
    return @a;
}

sub start_vm {
    my ($install) = @_;
    mlog "=== START qemu (install=" . ($install ? 'yes' : 'no') . ") ===";
    if (-f $PIDF) {
        open(my $fh, '<', $PIDF) or return undef;
        my $pid = <$fh>;
        close $fh;
        if ($pid && kill(0, $pid)) {
            mlog "already running pid=$pid";
            return undef;
        }
    }
    my ($rc, $out) = run(qemu_args($install));
    die "qemu failed rc=$rc   $out\n" if $rc != 0;
    my $ser = wait_port($SER_PORT);
    die "no serial port\n" unless $ser;
    return $ser;
}

sub graceful_halt {
    my ($s) = @_;
    mlog "=== GRACEFUL HALT ===";
    tx($s, "halt\r");
    my $pid = 0;
    if (-e $PIDF) {
        open(my $fh, '<', $PIDF) or return;
        $pid = <$fh>;
        close $fh;
    }
    my $dead = time + 120;
    while (time < $dead) {
        last unless $pid && kill 0, $pid;
        sleep 2;
    }
    if ($pid && kill 0, $pid) {
        mlog "halt timeout; stopping forcibly";
        stop_vm();
    }
}

sub stop_vm {
    my $mon = connect_tcp($MON_PORT, 5);
    if ($mon) {
        syswrite($mon, "system_powerdown\r");
        sleep 2;
        close $mon;
    }
    if (-e $PIDF) {
        open(my $fh, '<', $PIDF) or return;
        my $pid = <$fh>;
        close $fh;
        kill 'TERM', $pid if $pid;
    }
    sleep 2;
}

sub vm_status {
    if (!-e $PIDF) {
        print "stopped\n";
        return;
    }
    open(my $fh, '<', $PIDF) or return;
    my $pid = <$fh>;
    close $fh;
    $pid ||= -1;
    if (kill(0, $pid)) {
        print "running: $pid\n";
    } else {
        print "stopped: $pid\n";
    }
}

sub cmd_settty {
    my ($s) = @_;
    for my $attempt (1 .. 4) {
        mlog "=== SET-TTY ATTEMPT $attempt (README boot flow) ===";
        my ($i) = expect($s, 120, qr/boot>/i);
        die "no loader boot> prompt on serial\n" unless $i == 0;

        tx($s, "stty com0 115200\r");
        my ($j) = expect($s, 15, qr/boot>/i);
        die "loader lost after stty\n" unless $j == 0;

        tx($s, "set tty com0\r");
        my ($k) = expect($s, 15, qr/boot>/i);
        die "set tty com0 failed\n" unless $k == 0;
        mlog "switching console to com0 ok";

        tx($s, "boot\r\r\r");
        my ($m) = expect($s, 60, qr/\(I\)nstall,\s*\(U\)pgrade,\s*\(A\)utoinstall or \(S\)hell\?/i);
        if ($m == 0) {
            return 1;
        }
        mlog "installer menu not reached (attempt $attempt)";
        if ($attempt < 4) {
            monitor_cmd('system_reset');
            sleep 5;
        }
    }
    die "no installer menu after boot\n";
}

sub wait_prompt {
    my ($s, $timeout) = @_;
    my $dead = time + $timeout;
    my $sel  = IO::Select->new($s);
    while (1) {
        if ($BUF =~ m/(?:^|\n)[^\n]*[#$%]\s*\z/s) {
            mlog "prompt tail=" . substr($BUF, -60);
            $GOT = $BUF;
            $BUF = '';
            return 1;
        }
        my $left = $dead - time;
        last if $left <= 0;
        my @r = $sel->can_read($left);
        if (@r) {
            my $ch = '';
            my $n  = sysread($s, $ch, 16384);
            last unless defined $n && $n > 0;
            my $c = clean($ch);
            $BUF .= $c;
            dolog($c);
        }
    }
    mlog "timeout($timeout) tail=" . substr($BUF, -200);
    return 0;
}

sub run_guest {
    my ($s, $cmd) = @_;
    mlog "guest>> $cmd";
    tx($s, "$cmd\r");
    return wait_prompt($s, 120);
}

sub enter_shell {
    my ($s) = @_;
    my ($i) = expect($s, 10, qr/\(I\)nstall, \(U\)pgrade, \(A\)utoinstall or \(S\)hell\?/i);
    return 0 if $i < 0;
    tx($s, "S\r");
    return wait_prompt($s, 30);
}

sub install_shell_steps {
    my ($s) = @_;
    mlog "=== INSTALLER SHELL STEPS ===";

    unless (run_guest($s, 'sysctl hw.disknames')) { die "shell stuck\n" }

    run_guest($s, 'dmesg | grep wd[0-9]')
        or die "no wd\n";

    run_guest($s, "cd /dev; sh MAKEDEV sd0; sh MAKEDEV sd1; sh MAKEDEV sd2; ls -l sd*a")
        or die "makedev\n";

    run_guest($s, "dd if=/dev/zero of=/dev/rsd0c bs=1m count=100")
        or die "shred\n";

    run_guest($s, "fdisk -iy -g -b 960 sd0")
        or die "fdisk\n";

    run_guest($s, "{ echo 'a a'; echo; echo; echo raid; echo w; echo q; } | disklabel -E sd0; disklabel sd0")
        or die "disklabel -E\n";

    run_guest($s, "echo '$ROOT_PW' > /tmp/.passphrase; chmod 0600 /tmp/.passphrase; ls -l /tmp/.passphrase")
        or die "passphrase\n";

    run_guest($s, 'bioctl -p /tmp/.passphrase -c C -l sd0a softraid0')
        or die "bioctl\n";

    my $sd1 = 0;
    for (1 .. 5) {
        tx($s, "sysctl hw.disknames\r");
        expect($s, 10, qr/hw\.disknames=([^\r\n]+)/);
        if ($GOT =~ /sd1/) {
            $sd1 = 1;
            last;
        }
    }
    die "sd1 not created\n" unless $sd1;

    tx($s, "\x04\r");
    my ($i) = expect($s, 30, qr/\(I\)nstall, \(U\)pgrade, \(A\)utoinstall or \(S\)hell\?/i);
    return 1 if $i >= 0;
    return 0;
}

sub dlg {
    my ($s, $timeout, $look, $sendtxt) = @_;
    my ($i) = expect($s, $timeout, $look);
    die "dialog lost at: $look\n" if $i < 0;
    tx($s, $sendtxt);
    return 1;
}

sub install_dialog {
    my ($s) = @_;
    mlog "=== INSTALL DIALOG ===";

    tx($s, "I\r");
    dlg($s, 30, qr/Terminal type\??/i, "vt220\r");
    dlg($s, 30, qr/System hostname\??/i, "$HOST\r");
    dlg($s, 30, qr/Network interface to configure\??/i, "done\r");
    dlg($s, 30, qr/DNS domain name\??/i, "$DOMAIN\r");
    dlg($s, 30, qr/DNS nameservers\??/i, "1.1.1.1\r");
    dlg($s, 30, qr/Password for root account\??/i, '');
    txh($s, "$ROOT_PW\r");
    dlg($s, 30, qr/again\)\??/i, '');
    txh($s, "$ROOT_PW\r");
    dlg($s, 30, qr/Start sshd\(8\) by default\??/i, "no\r");
    dlg($s, 30, qr/xenodm\(1\)\?/i, "no\r");
    dlg($s, 30, qr/Change the default console to com0\??/i, "yes\r");
    dlg($s, 30, qr/Which speed should com0 use\??/i, "115200\r");
    dlg($s, 30, qr/Setup a user\??/i, "no\r");

    dlg($s, 30, qr/Which disk is the root disk\??/i, "sd1\r");

    dlg($s, 30, qr/Use \(W\)hole disk MBR, whole disk \(G\)PT/i, "gpt\r");

    dlg($s, 30, qr/\(A\)uto layout, \(E\)dit auto layout, or create \(C\)ustom layout\?/i, "c\r");

    dlg($s, 30, qr/\n\w+\*?>\s/, "a a\r");
    dlg($s, 30, qr/offset:\s*/, "\r");
    dlg($s, 30, qr/size:\s*/, "90%\r");
    dlg($s, 30, qr/FS type:\s*/, "\r");
    dlg($s, 30, qr/mount point:\s*/, "/\r");
    dlg($s, 30, qr/\n\w+\*?>\s/, "a b\r");
    dlg($s, 30, qr/offset:\s*/, "\r");
    dlg($s, 30, qr/size:\s*/, "*\r");
    dlg($s, 30, qr/FS type:\s*/, "swap\r");
    dlg($s, 30, qr/\n\w+\*?>\s/, "w\r");
    dlg($s, 30, qr/\n\w+\*?>\s/, "p\r");
    dlg($s, 30, qr/\n\w+\*?>\s/, "q\r");

    dlg($s, 30, qr/Which disk do you wish to initialize\??/i, "done\r");

    dlg($s, 60, qr/Location of sets\??/i, "disk\r");
    dlg($s, 30, qr/Is the disk partition already mounted\??/i, "no\r");
    dlg($s, 30, qr/Which disk contains the install media\??/i, "wd0\r");
    dlg($s, 30, qr/Which wd0 partition has the install sets\??/i, "a\r");
    dlg($s, 30, qr/Pathname to the sets\??/i, "\r");
    dlg($s, 30, qr/Set name\(s\)\??/i, "-game*\r\r");
    dlg($s, 30, qr/Continue without verification\??/i, "yes\r");

    mlog "installing sets (long)";
    my ($i) = expect($s, 3600, qr/Location of sets\?.*?\[done\]/mi);
    die "sets install failed\n" if $i < 0;
    tx($s, "done\r");

    dlg($s, 60, qr/What timezone are you in\??/i, "$TZ\r");

    my ($j) = expect($s, 300, qr/^(Exit to \(S\)hell|congratulations!)/mi);
    die "no exit prompt\n" if $j < 0;
    tx($s, "S\r");
    return wait_prompt($s, 30);
}

sub post_install_serial {
    my ($s) = @_;
    mlog "=== UEFI BOOT LOADER + HALT ===";

    my $efi_dev = '/dev/sd0i';
    mlog "using EFI partition $efi_dev";

    run_guest($s, "newfs_msdos -L EFI $efi_dev; mount $efi_dev /mnt2")
        or die "newfs/mount efi\n";

    run_guest($s, "mkdir -p /mnt2/efi/boot; cp /mnt/usr/mdec/BOOTX64.EFI /mnt2/efi/boot/; ls -l /mnt2/efi/boot")
        or die "copy efi\n";

    run_guest($s, "umount /mnt2; df -h /mnt2 2>&1; mount | grep mnt2")
        or die "umount\n";

    run_guest($s, "echo 'swap /tmp mfs rw,nodev,nosuid,-s=300m 0 0' >> /mnt/etc/fstab; chmod 1777 /mnt/tmp")
        or die "fstab mfs\n";

    mlog "halt machine";
    tx($s, "halt\r; true\r");
    my $deadline = time + 90;
    while (time < $deadline) {
        last unless -e $PIDF;
        sleep 1;
    }
    sleep 5;
}

sub monitor_cmd {
    my ($cmd) = @_;
    my $m = connect_tcp($MON_PORT, 5);
    return 0 unless $m;
    syswrite($m, "$cmd\r");
    sleep 2;
    my $end = time + 3;
    while (time < $end) {
        my $r = '';
        my $n = sysread($m, $r, 4096);
        last unless defined($n) && $n > 0;
    }
    close $m;
    return 1;
}

sub login_serial {
    my ($s) = @_;
    mlog "=== SERIAL LOGIN ===";
    tx($s, "\r\r\r");
    return 0 if expect($s, 120, qr/login:/i) < 0;
    tx($s, "root\r");
    return 0 if expect($s, 30, qr/[Pp]assword:/i) < 0;
    txh($s, "$ROOT_PW\r");
    return wait_prompt($s, 30);
}

sub boot_once {
    my ($s) = @_;
    mlog "=== BOOT ONCE ===";
    my ($i) = expect($s, 120, qr/boot>/i, qr/[Pp]assphrase:/i, qr/booting.*/i, qr/login:/i);
    if ($i == 1) {
        txh($s, "$ROOT_PW\r");
        $i = expect($s, 90, qr/boot>/i, qr/booting.*/i, qr/login:/i, qr/[Pp]assphrase:/i);
    } elsif ($i == 0) {
        txh($s, "set device sr0a\r");
        expect($s, 15, qr/boot>/i);
        txh($s, "\r");
        my ($j) = expect($s, 90, qr/[Pp]assphrase:/i);
        if ($j >= 0) {
            txh($s, "$ROOT_PW\r");
        }
        $i = expect($s, 90, qr/boot>/i, qr/booting.*/i, qr/login:/i, qr/[Pp]assphrase:/i);
    }
    if ($i == 0) {
        select undef, undef, undef, 2;
        txh($s, "boot /bsd\r");
        expect($s, 120, qr/booting.*/i);
    } elsif ($i == 1) {
        expect($s, 120, qr/booting.*/i, qr/login:/i);
    } elsif ($i < 0) {
        mlog "no boot prompt at all";
        return 0;
    }
    return login_serial($s);
}

sub ssh_target {
    if (net_mode() eq 'user') {
        $SSH_HOST = '127.0.0.1';
        $SSH_PORT = $FW_PORT;
        return 1;
    }
    return 0;
}

sub discover_guest_ip {
    my ($s) = @_;
    return ssh_target() if ssh_target();
    my $ip = '';
    for (1 .. 6) {
        txh($s, "ifconfig vio0 | grep inet\r");
        my $i = expect($s, 8, qr/inet\s+(\d+\.\d+\.\d+\.\d+)/);
        if ($i >= 0) {
            ($ip) = $GOT =~ /inet\s+(\d+\.\d+\.\d+\.\d+)/;
            last if $ip;
        }
        sleep 3;
    }
    if ($ip) {
        $SSH_HOST = $ip;
        open(my $fh, '>', $IPFILE) or warn "ipfile: $!\n";
        print $fh "$ip\n";
        close $fh;
        mlog "guest ip: $ip";
    }
    return $ip;
}

sub boot_installed {
    my ($s) = @_;
    for my $attempt (1 .. 4) {
        my $ok = boot_once($s);
        return 1 if $ok;
        mlog "boot attempt $attempt failed";
        if ($attempt < 4) {
            mlog "system_reset and retry";
            monitor_cmd('system_reset');
            sleep 4;
        }
    }
    mlog "all boot attempts failed";
    return 0;
}

sub adduser_serial {
    my ($s) = @_;
    mlog "=== ADD USER ===";
    tx($s, "adduser\r");

    my ($c) = expect($s, 30, qr/Couldn't find \/etc\/adduser\.conf/i, qr/Enter username/i, qr/\n[^\n]*#\s/);
    if ($c == 0) {
        dlg($s, 30, qr/Enter your default shell:/i, "ksh\r");
        dlg($s, 30, qr/Default login class:/i, "default\r");
        dlg($s, 30, qr/Enter your default HOME partition:/i, "/home\r");
        dlg($s, 30, qr/Copy dotfiles from:/i, "/etc/skel\r");
        dlg($s, 30, qr/Send welcome message\??/i, "no\r");
        dlg($s, 30, qr/Prompt for passwords by default/i, "no\r");
        dlg($s, 30, qr/Default encryption method for passwords:/i, "blowfish\r");
        my ($f) = expect($s, 30, qr/Enter username/i, qr/\n[^\n]*#\s/);
        return 0 if $f != 0;
        tx($s, "$USER\r");
    } elsif ($c == 1) {
        tx($s, "$USER\r");
    } elsif ($c == 2 || $c < 0) {
        return 0;
    }

    dlg($s, 30, qr/Enter full name/i, "\r");
    dlg($s, 30, qr/Enter shell/i, "ksh\r");
    dlg($s, 30, qr/^Uid \[\d+\]/mi, "$UID\r");
    dlg($s, 30, qr/Login group/i, "$GROUP\r");
    dlg($s, 30, qr/Invite a into other groups/i, "no\r");
    dlg($s, 30, qr/Login class/i, "default\r");
    dlg($s, 30, qr/^OK\??/mi, "y\r");
    dlg($s, 30, qr/Add another user\??/i, "n\r");
    return wait_prompt($s, 15);
}

sub ssh_raw {
    my ($user, $remote) = @_;
    ssh_target() unless $SSH_HOST && length $SSH_HOST;
    unless ($SSH_HOST && length $SSH_HOST) {
        if (-f $IPFILE) {
            open(my $fh, '<', $IPFILE);
            $SSH_HOST = <$fh>;
            close $fh;
            chomp $SSH_HOST;
        }
    }
    return (255, "no guest ip\n") unless $SSH_HOST;
    my $ssh = "ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o ConnectTimeout=5 -i $SSHKEY -p $SSH_PORT $user\@$SSH_HOST -- " . shq($remote) . " 2>&1";
    my $out = `$ssh`;
    my $rc  = $? >> 8;
    return ($rc, $out);
}

sub ssh_doas {
    my ($cmd) = @_;
    my ($rc, $out) = ssh_raw($USER, "doas sh -c " . shq($cmd));
    mlog "doas rc=$rc out=" . substr($out, 0, 1000) if $out;
    return ($rc, $out);
}

sub ssh_user {
    my ($cmd) = @_;
    my ($rc, $out) = ssh_raw($USER, $cmd);
    mlog "user rc=$rc out=" . substr($out, 0, 1000) if $out;
    return ($rc, $out);
}

sub post_install_ssh_setup {
    my ($s) = @_;
    mlog "=== POST INSTALL (SERIAL SETUP) ===";

    adduser_serial($s) or die "adduser failed\n";

    run_guest($s, "mkdir -p /home/$USER/.ssh; chmod 700 /home/$USER/.ssh")
        or die "ssh dir\n";

    run_guest($s, "echo '$PUBKEY' > /home/$USER/.ssh/authorized_keys")
        or die "pubkey\n";

    run_guest($s, "chmod 600 /home/$USER/.ssh/authorized_keys; chown -R $USER:$GROUP /home/$USER/.ssh")
        or die "chown\n";

    run_guest($s, "echo 'permit nopass :staff' > /etc/doas.conf")
        or die "doas\n";

    run_guest($s, "perl -i -pE 's/[#]?(Banner)\\s.*/Banner none/x; s/[#]?(PrintMotd)\\s.*/PrintMotd no/x; s/[#]?(PasswordAuthentication)\\s.*/PasswordAuthentication no/x; s/[#]?(PermitRootLogin)\\s.*/PermitRootLogin no/x; s/[#]?(X11Forwarding)\\s.*/X11Forwarding yes/x' /etc/ssh/sshd_config")
        or die "sshd config\n";

    run_guest($s, "rm -f /etc/motd; ln -sf /dev/null /etc/motd; printf '\\n' > /etc/motd")
        or die "motd\n";

    run_guest($s, "echo 'dhcp' > /etc/hostname.vio0; cat /etc/hostname.vio0")
        or die "hostname\n";

    run_guest($s, "rcctl enable sshd; rcctl start sshd")
        or die "sshd start\n";

    run_guest($s, "echo 'nameserver 8.8.8.8' > /etc/resolv.conf")
        or die "resolv\n";

    run_guest($s, "sh /etc/netstart")
        or die "netstart\n";

    discover_guest_ip($s);

    my ($rc, $out) = run('ssh-keyscan', '-p', $SSH_PORT, '-H', $SSH_HOST) if $SSH_HOST;
    my $scan_out = '';
    if ($rc == 0 && $out) {
        my @lines = grep { !/^\s*#/ && /\S/ } split /\n/, $out;
        $scan_out = join("\n", @lines) . "\n";
    }
    open(my $fh, '>', $KNOWN_HOSTS);
    print $fh $scan_out unless $scan_out eq "\n";
    close $fh;

    my $deadline = time + 120;
    my $ready    = 0;
    while (time < $deadline) {
        my ($r, $o) = ssh_user('id');
        if ($r == 0 && $o =~ /uid=$UID\b/) {
            $ready = 1;
            last;
        }
        sleep 3;
    }
    die "ssh not ready\n" unless $ready;
    mlog "SSH READY";
    return 1;
}

sub post_extras {
    mlog "=== POST EXTRAS ===";

    for my $pk (qw(sudo git gnupg wget rsync bash curl htop)) {
        my ($rc, $out) = ssh_doas("pkg_add -x $pk");
        mlog "pkg $pk rc=$rc";
    }

    my ($rc, $out) = ssh_doas("fw_update -a");
    mlog "fw_update rc=$rc";

    ssh_doas("perl -i.bak -nE 'print unless /com0/' /etc/boot.conf");
    ssh_doas("echo 'machine gop $GOP' | tee -a /etc/boot.conf");
    ssh_doas("rcctl disable ntpd && rcctl stop ntpd");
    ssh_doas("perl -i.bak -pE 's/(?<=rw)(?!,noatime)/,noatime/' /etc/fstab");
    ssh_doas("perl -i.bak -pE 's/(?<=rw)(?!,softdep)/,softdep/' /etc/fstab");
    ssh_doas("rcctl set sndiod flags -b24000");
    ssh_doas("rcctl restart sndiod");
    ssh_doas("echo 'keyboard.bell.volume=0' | tee /etc/wsconsctl.conf && echo 'keyboard.map+=\"keysym Caps_Lock = Control_L\"' | tee -a /etc/wsconsctl.conf && echo 'display.screen_off=60000' | tee -a /etc/wsconsctl.conf");
    ssh_doas("echo 'vm.swapencrypt.enable=1' | tee /etc/sysctl.conf && echo 'machdep.lidaction=2' | tee -a /etc/sysctl.conf && echo 'machdep.pwraction=1' | tee -a /etc/sysctl.conf");

    my ($rc2, $o2) = ssh_user("test -x /usr/local/bin/bash && doas chsh -s /usr/local/bin/bash $USER 2>&1 || echo bash-not-installed");
    mlog "chsh rc=$rc2 $o2";
}

sub cmd_all {
    prep();

    my $s = start_vm(1);
    die "vm already running\n" unless $s;
    cmd_settty($s)            or die "set-tty failed\n";
    install_shell_steps($s)   or die "install_shell_steps failed\n";
    install_dialog($s)        or die "install_dialog failed\n";
    post_install_serial($s)   or die "post_install_serial failed\n";
    stop_vm();
    close $s;

    $s = start_vm(0);
    boot_installed($s)        or die "boot_installed failed\n";
    post_install_ssh_setup($s) or die "post_install_ssh_setup failed\n";
    close $s;

    my ($rc, $out) = ssh_user('echo openbsd-ok; uname -a; id');
    mlog "FINAL ssh rc=$rc out=$out";
    print "FINAL: $out\n" if $rc == 0;
    post_extras();
    mlog "=== DONE ===";
}

sub cmd_install {
    prep();
    my $s = start_vm(1);
    die "vm already running\n" unless $s;
    cmd_settty($s);
    install_shell_steps($s);
    install_dialog($s);
    post_install_serial($s);
    stop_vm();
    close $s;
}

sub cmd_boot {
    prep();
    my $s = start_vm(0);
    die "vm already running\n" unless $s;
    boot_installed($s);
    discover_guest_ip($s);
    close($s);
    print "booted " . ($SSH_HOST || '') . "; pidfile=" . (-e $PIDF ? 'yes' : 'no') . "\n";
    while (1) {
        sleep 60;
    }
}

sub cmd_setup {
    my $s = connect_tcp($SER_PORT, 5);
    die "no serial\n" unless $s;
    post_install_ssh_setup($s);
    mlog "=== SETUP DONE ===";
    graceful_halt($s);
}

sub cmd_login {
    my $s = connect_tcp($SER_PORT, 5);
    die "no serial\n" unless $s;
    print "serial interactive; Ctrl-C detaches\n";
    binmode STDIN;
    my $sel = IO::Select->new($s);
    $sel->add(\*STDIN);
    while (1) {
        for my $fh ($sel->can_read(5)) {
            if ($fh == $s) {
                my $ch = '';
                my $n  = sysread($fh, $ch, 4096);
                if (!defined($n) || $n == 0) {
                    exit 0;
                }
                print clean($ch);
                dolog(clean($ch));
            } else {
                my $ch = '';
                my $n  = sysread($fh, $ch, 4096);
                syswrite($s, $ch) if $n;
            }
        }
    }
}

my $CMD = shift @ARGV // 'all';
prep();
if ($CMD eq 'install') {
    cmd_install();
} elsif ($CMD eq 'boot') {
    cmd_boot();
} elsif ($CMD eq 'setup') {
    cmd_setup();
} elsif ($CMD eq 'login') {
    cmd_login();
} elsif ($CMD eq 'all') {
    cmd_all();
} elsif ($CMD eq 'prep') {
    print "prep done\n";
} elsif ($CMD eq 'stop') {
    stop_vm();
} elsif ($CMD eq 'status') {
    vm_status();
} else {
    die "unknown command: $CMD\n";
}