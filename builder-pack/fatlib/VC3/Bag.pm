#
# Copyright (C) 2016- The University of Notre Dame
# This software is distributed under the GNU General Public License.
# See the file COPYING for details.
#

use v5.09;
use strict;
use warnings;

package VC3::Bag; 

use Carp qw/carp croak/;
#use English qw/-mo_match_vars/;
use File::Basename;
use File::Copy;
use File::Spec::Functions qw/catfile rel2abs file_name_is_absolute/;
use File::Temp qw/tempfile/;
use FindBin  qw/$RealBin $RealScript/;
use JSON::Tiny;
use List::Util qw/first max/;
use POSIX ();
use Tie::RefHash;
use version ();

use VC3::Plan;
use VC3::Package;

sub new {
    my ($class, %args) = @_;
    
    #args:
    #    root       
    #    home       
    #    distfiles  
    #    repository 
    #    shell      
    #    dry_run    
    #    on_terminal
    #    silent     
    #    databases  
    #    pkg_opts  
    #    sys_manual 
    #    no_sys     
    #    env_vars   

    my $self = bless {}, $class;

    $self->{dry_run}     = $args{dry_run};
    $self->{on_terminal} = $args{on_terminal};
    $self->{silent_run}  = $args{silent};

    # clean generated shell profile by default
    $self->preserve_profile(0);

    # root, home, shell, etc.
    $self->set_builder_variables($args{root}, $args{home}, $args{shell}, $args{distfiles}, $args{repository});

    # read the catalog of available packages
    my $recipes_raw = $self->read_bags($args{databases});

    $self->{recipes}{op_sys_distro} = $self->decode_recipes($recipes_raw->{op_sys_distro}, $args{pkg_opts});
    # arch, distro, etc.
    $self->set_machine_vars();

    $self->{recipes}{op_sys}  = $self->decode_recipes($recipes_raw->{op_sys}, $args{pkg_opts});
    $self->{recipes}{package} = $self->decode_recipes($recipes_raw->{package}, $args{pkg_opts});

    if(%{$args{pkg_opts}}) {
        warn 'The options for these packages were unused: ', join(',', keys %{$args{pkg_opts}}) . "\n";
    }

    $self->{no_system} = { map { ( $_ => 1 ), } @{$args{no_sys}} };
    $self->{system}    = {};

    # always use singularity from the system (we can't compile it as a user.)
    $self->{system}{singularity} = 1;

    $self->{indent_level} = 0;

    $self->add_manual_variables($args{env_vars});
    $self->add_manual_packages($args{sys_manual});

    $self->write_db();

    return $self;
}

sub to_hash {
    my ($self) = @_;

    my $bh = {};

    for my $subbag (values %{$self->{recipes}}) {
        for my $p (values %{$subbag}) {
            $bh->{$p->name} = $p->original_description();
        }
    }

    return $bh;
}

sub write_db {
    my ($self) = @_;

    my $rec_file = $self->sh_profile . '.recipes';

    # write recipes
    open(my $sh_f_recp, '>', $rec_file)
    || die "Could not open file $rec_file $!";


    my $json = JSON::Tiny::encode_json($self->to_hash);
    print { $sh_f_recp } "$json";
    close($sh_f_recp);
}

sub list_packages() {
    my ($self, $option) = @_;

    my @ps;
    if($option eq 'os') {
        @ps = values %{$self->{recipes}{op_sys}};
    } else {
        @ps = values %{$self->{recipes}{package}};
    }

    if($option ne 'all') {
        @ps = grep { $_->show_in_list } @ps;
    }

    my $by_tags = ($option eq 'section');

    my %tags;
    for my $p (@ps) {
        my @ts = ($by_tags && $p->tags) ? @{$p->tags} : ('other');

        for my $t (@ts) {
            $tags{$t} ||= [];
            push @{$tags{$t}}, $p;
        }
    }

    my @tagnames = sort { $a cmp $b } keys %tags;

    @tagnames = grep { ! m/other/ } @tagnames;
    push @tagnames, 'other';

    for my $t (@tagnames) {
        if(defined $tags{$t}) {

            my @ps = sort { $a->name cmp $b->name } @{$tags{$t}};

            if($by_tags) {
                print "\n--- $t\n";
            }

            for my $p (@ps) {
                my $printed = {};
                my $ws = $p->widgets;

                for my $w (@{$ws}) {
                    my $version = $w->from_system ? 'auto' : $w->version;

                    my $str = $p->name . ':' . $version;

                    unless(defined $printed->{$str}) {
                        $printed->{$str} = 1;
                        print "$str\n";
                    }
                }
            }
        }
    }
}

sub check_manual_requirements() {
    my ($self) = @_;

    my @restricted_unmet;
    for my $w (@{$self->plan->order}) {
        my $msg = $w->msgs_manual_requirements();
        if($msg) {
            $self->activate_widget($w);
            push @restricted_unmet, $w->msgs_manual_requirements();
        }
    }

    if(@restricted_unmet > 0) {
        my ($pid, $build_in) = $self->shell();

        print { $build_in } "cat <<EOF\n";

        for my $msg (@restricted_unmet) {
            for my $line (@{$msg}) {
                print { $build_in } "$line\n";
            }
            print { $build_in } "\n";
        }

        print { $build_in } "EOF\n";
        print { $build_in } "exit 0\n";

        die "\n";
    }

    return 1;
}

sub active_widgets {
    my ($self) = @_;

    unless($self->{active_widgets}) {
        my %new;
        tie %new, 'Tie::RefHash';

        $self->{active_widgets} = \%new;
    }

    return $self->{active_widgets};
}

sub active_widgets_vars {
    my ($self) = @_;

    unless($self->{active_widgets_vars}) {
        my %new;
        tie %new, 'Tie::RefHash';

        $self->{active_widgets_vars} = \%new;
    }

    return $self->{active_widgets_vars};
}

sub activate_widget {
    my ($self, $widget) = @_;
    $self->activate_widget_vars($widget);
    $self->active_widgets->{$widget} = 1;
}

sub activate_widget_vars {
    my ($self, $widget) = @_;
    $self->active_widgets_vars->{$widget} = 1;
}

sub set_builder_variables {
    my ($self, $root, $home, $shell, $distfiles, $repository) = @_;

    $self->{environment_variables} = [];

    $self->root_dir($root);
    $self->home_dir($home);
    $self->files_dir($distfiles);
    $self->tmp_dir($self->with_root('tmp'));

    $self->repository($repository);

    $self->shell_executable($shell);

    # the var $> has the effective uid of the current user
    $self->user_uid($>);

    # the var $) has the effective groups of the current user
    $self->user_gid($));

    $self->user_name($ENV{'USER'} || getpwuid($self->user_uid) || 'vc3-user');

    my $executable = $RealScript;
    if($executable eq '-e') {
        # this will break! BUG. How to know the name of static executable?
        $executable = 'vc3-builder-static';
    }

    $self->builder_path(catfile($RealBin, $executable));

    eval {
        File::Path::make_path($self->root_dir);
        File::Path::make_path($self->files_dir);
        File::Path::make_path(catfile($self->files_dir, 'manual-distribution'));
        File::Path::make_path(catfile($self->files_dir, 'images', 'singularity'));
        File::Path::make_path(catfile($self->files_dir, 'images', 'docker'));
        File::Path::make_path($self->home_dir);
        File::Path::make_path($self->tmp_dir);
    };

    if($@) {
        my $error = $@;
        $error =~ s/ at .*$//;
        warn("Could not create some directory: $error");
        warn("giving up...\n");
        exit 1;
    }

    my ($profile_f, $profile_name) = tempfile(catfile($self->home_dir, '.vc3_sh-XXXXXX'));
    close $profile_f;
    $self->sh_profile($profile_name);

    $self->add_builder_variable('VC3_ROOT',         $self->root_dir);
    $self->add_builder_variable('VC3_DISTFILES',    $self->files_dir);
    $self->add_builder_variable('VC3_BUILDER_PATH', $self->builder_path);
    $self->add_builder_variable('VC3_INSTALL_USER_HOME', $self->home_dir);
    $self->add_builder_variable('TMP',              $self->tmp_dir);
    $self->add_builder_variable('TERM',             $ENV{'TERM'} || 'xterm');
    $self->add_builder_variable('CC',               $ENV{'CC'}   || 'gcc');
    $self->add_builder_variable('CXX',              $ENV{'CXX'}  || 'g++');
    $self->add_builder_variable('SHELL',            $self->shell_executable);

    # we don't want to overwrite these variables in the general profile:
    # $self->add_builder_variable('USER',
    # $self->add_builder_variable('HOME',             $self->home_dir);
}

sub DESTROY {
    my ($self) = @_;
    $self->cleanup();
}

sub root_dir {
    my ($self, $root) = @_;

    if($root) {
        $root = glob $root; # expand ~
        $root = rel2abs($root);
        $self->{root_dir} = $root;
    }

    return $self->{root_dir};
}

sub repository {
    my ($self, $shell) = @_;

    if($shell) {
        $self->{repository} = $shell;
    }

    return $self->{repository};
}

sub shell_executable {
    my ($self, $shell) = @_;

    if($shell) {
        $self->{shell_executable} = $shell;
    }

    return $self->{shell_executable};
}

sub home_dir {
    my ($self, $home) = @_;

    if($home) {
        $home = glob $home; # expand ~

        unless(file_name_is_absolute($home)) {
            $home = $self->with_root($home);
        }

        $home = rel2abs($home);
        $self->{home_dir} = $home;
    }

    return $self->{home_dir};
}

sub files_dir {
    my ($self, $files) = @_;

    if($files) {
        $files = glob $files; # expand ~
        $files = rel2abs($files);
        $self->{files_dir} = $files;
    }

    return $self->{files_dir};
}

sub tmp_dir {
    my ($self, $tmp) = @_;

    if($tmp) {
        $tmp = glob $tmp; # expand ~
        $tmp = rel2abs($tmp);
        $self->{tmp_dir} = $tmp;
    }

    return $self->{tmp_dir};
}

sub with_root {
    my ($self, $dir) = @_;

    return catfile($self->root_dir, $dir);
}

sub user_name {
    my ($self, $name) = @_;

    $self->{user_name} = $name if($name);

    return $self->{user_name};
}

sub user_uid {
    my ($self, $uid) = @_;

    if(defined $uid) {
        $self->{user_uid} = $uid;
    }

    return $self->{user_uid};
}

sub user_gid {
    my ($self, $gids) = @_;

    if(defined $gids) {
        my @all = split(' ', $gids);
        $self->{user_gid} = $all[0];
    }

    return $self->{user_gid};
}

sub on_terminal {
    my ($self, $ont) = @_;

    $self->{on_terminal} = $ont if($ont);

    return $self->{on_terminal};
}


sub plan {
    my ($self, $new) = @_;

    $self->{plan} = $new if($new);

    return $self->{plan};
}

sub builder_path {
    my ($self, $new) = @_;

    $self->{builder} = $new if($new);

    return $self->{builder};
}


sub sh_profile {
    my ($self, $init) = @_;

    $self->{sh_profile} = $init if($init);

    return $self->{sh_profile};
}

sub dry_run {
    my ($self) = @_;
    return $self->{dry_run};
}

sub preserve_profile {
    my ($self, $val) = @_;

    if(defined $val) {
        $self->{preserve_profile} = $val;
    }

    unless(defined $self->{preserve_profile}) {
        # do not preserve profile by default.
        $self->{preserve_profile} = 0;
    }

    return $self->{preserve_profile};
}


sub environment_variables {
    my ($self, $new_vars) = @_;

    $self->{environment_variables} = $new_vars if($new_vars);

    return $self->{environment_variables};
}

sub add_builder_variable {
    my ($self, $name, $value) = @_;

    my $var = {
        name     => $name,
        value    => $value,
        clobber  => 1,
        absolute => 1
    };

    my $vars = $self->environment_variables;
    push @{$vars}, $var;

    return $var;
}

sub add_manual_variables {
    my ($self, $extra_vars) = @_;

    for my $var (@{$extra_vars}) {
        $var =~ m/
        ^
        (?<name>[A-Za-z_][A-Z-a-z_0-9]*)
        =
        (?<value>.*)
        $
        /x or die "Malformed variable specification: '$var'";

        $self->add_builder_variable($+{name}, $+{value});
    }
}


sub add_manual_packages {
    my ($self, $specs) = @_;

    for my $spec (@{$specs}) {
        my ($name, $version, $dir);

        if(
            $spec =~ m/
            ^
            (?<name>[A-Za-z_][A-Z-a-z_0-9]*)
            :
            (?<version>(([0-9]+(\.?[0-9]){0,3})|auto))
            (=(?<dir>.*))?
            $
            /x
        ) {
            ($name, $version, $dir) = @+{qw(name version dir)};
            $dir ||= '/usr';
        } else {
            die "Malformed manual specification: '$spec'\n";
        }

        my $pkg = $self->{recipes}{package}{$name};
        unless($pkg) {
            die "Could not find specification to overwrite for '$name'\n";
        }

        if($version eq 'auto') {
            $version = $pkg->compute_auto_version($dir);
        }

        my $s = {};
        $s->{version} = $version;
        $s->{source} = {
            type   => 'system',
            recipe => [
                "echo VC3_ROOT_SYSTEM: $dir"
            ]
        };

        $self->{system}{$name} = 1;

        my $widgets = $pkg->widgets;
        unshift @{$widgets}, VC3::Widget->new($pkg, $s);
    }
}

sub del_builder_variable {
    my ($self, $name) = @_;

    my @vars = @{$self->environment_variables};
    @vars = grep { $name ne $_->{name} } @vars;

    $self->environment_variables(\@vars);
}

sub set_plan_for {
    my ($self, @requires) = @_;

    $self->{indent_level} = 0;

    my $plan = VC3::Plan->new($self);
    $self->plan($plan);

    if(!$plan->add_main_targets(@requires)) {
        die("Could not find an installation plan.\n");
    }

    $plan->order(1);
}

sub execute_plan {
    my ($self, $sh_on_error, $force_rebuild, $ignore_locks) = @_;

    for my $w (@{$self->plan->order}) {
        $self->activate_widget_vars($w);
        $self->build_widget($w, $sh_on_error, $force_rebuild, $ignore_locks);
        $self->activate_widget($w);
    }
}

sub cleanup {
    my ($self) = @_;

    if($self->{child_pid}) {
        $self->say('Cleaning payload with pid: ' . $self->{child_pid});
        # send HUP to all processes
        kill -1, $self->{child_pid};
    }

    unless($self->preserve_profile) {

        if(defined $self->sh_profile) {
            if(-f $self->sh_profile) {
                unlink $self->sh_profile;
            }

            if(-f $self->sh_profile . '.env') {
                unlink $self->sh_profile . '.env';
            }

            if(-f $self->sh_profile . '.prologue') {
                unlink $self->sh_profile . '.prologue';
            }

            if(-f $self->sh_profile . '.wrapper') {
                unlink $self->sh_profile . '.wrapper';
            }

            if(-f $self->sh_profile . '.payload') {
                unlink $self->sh_profile . '.payload';
            }

            if(-f $self->sh_profile . '.recipes') {
                unlink $self->sh_profile . '.recipes';
            }
        }

        $self->del_builder_variable('VC3_SH_PROFILE_ENV');
        $self->del_builder_variable('VC3_SH_PROFILE_WRAPPER');
    }

    if($self->{child_pid}) {
        # give 10 seconds for child to cleanup HUP, then REDRUM
        for my $i (1..10) {
            my $n = waitpid(-1, POSIX::WNOHANG);
            if($n < 0) {
                $self->{child_pid} = undef;
                return;
            } else {
                $self->say('Waiting for payload with pid: ' . $self->{child_pid} . "  $n");
                VC3::Builder::select_sleep(1);
            }
        }
        $self->say('Hard terminating for payload with pid: ' . $self->{child_pid});

        # KILL to anybody
        kill -9, $self->{child_pid};
        $self->{child_pid} = undef;
    }
}

sub set_machine_vars {
    my ($self) = @_;

    ($self->{osname}, undef, undef, undef, $self->{architecture}) = POSIX::uname();

    $self->{distribution} = $self->find_distribution();

    $self->{target} = catfile($self->architecture, $self->distribution);


    my $ldd_version_raw = qx(ldd --version);
    $ldd_version_raw =~ /
    # we are looking for a line starting with 'ldd'
    ^ldd
    # followed by anything
    .*
    # followed by at least one space
    \s+
    # followed by the version number (that we capture)
    ([0-9.]+)
    # followed by any number of spaces at the end of the line
    \s*$
    # options: x allows regexp comments. m treats each line indepedently
    /xm ;

    $self->{glibc_version} = $1
    || 'unknown';

    $self->add_builder_variable('VC3_MACHINE_OS',            catfile($self->{osname}, $self->distribution));
    $self->add_builder_variable('VC3_MACHINE_ARCH',          $self->architecture);
    $self->add_builder_variable('VC3_MACHINE_GLIBC_VERSION', $self->glibc_version);
    $self->add_builder_variable('VC3_MACHINE_TARGET',        $self->{target});
}

sub target {
    my ($self) = @_;
    return $self->{target};
}

sub osname {
    my ($self) = @_;
    return $self->{osname};
}

sub architecture {
    my ($self) = @_;
    return $self->{architecture};
}

sub glibc_version {
    my ($self) = @_;
    return $self->{glibc_version};
}

sub distribution {
    my ($self) = @_;
    return $self->{distribution};
}

# reads /etc/readhat-release and transforms something like:
# 'Red Hat Enterprise Linux Server release 6.5 (Santiago)'
# into 'redhat6'.
# or /etc/debian_version into 'debian9
# etc.
sub find_distribution {
    my ($self) = @_;
    my $distribution;

    my @wheres = values %{$self->{recipes}{op_sys_distro}};

    @wheres = sort { $a->name cmp $b->name } @wheres;

    for my $p (@wheres) {
        for my $w (@{$p->widgets}) {
            my $exit_status = -1;
            eval { $exit_status = $w->source->check_prerequisites() };
            if($exit_status) {
                next;
            }

            eval { $distribution = $w->compute_os_distribution(); };
            if($@) {
                next;
            }

            if($distribution) {
                return $distribution;
            }
        }
    }

    warn "Could not find any OS version. Using 'generic'\n";
    return 'generic';
}

sub widgets_of {
    my ($self, $name) = @_;

    my $pkg = $self->{recipes}{package}{$name}
    || die "I do not know anything about '$name' . \n";

    return $pkg->widgets;
}

sub read_bags {
    my ($self, $databases) = @_;

    my $recipes  = {};
    $recipes->{package} = {};
    $recipes->{op_sys}  = {};
    $recipes->{op_sys_distro} = {};

    for my $filespec (@{$databases}) {
        if(-d $filespec) {
            $self->read_bag_dir($filespec, 1, $recipes);
        } elsif(-f $filespec) {
            $self->read_bag_file($filespec, $recipes);
        } elsif($filespec eq '<internal>') {
            $self->read_bag_internal($recipes);
        }
    }

    return $recipes;
}

sub read_bag_dir {
    my ($self, $dir, $depth, $recipes) = @_;

    if($depth > 32) {
        die "Maximum directory depth allowed reached.\n";
    }

    my @listing = sort { $a cmp $b } glob catfile($dir, '*');

    for my $filespec (@listing) {
        if(-d $filespec) {
            $self->read_bag_dir($filespec, $depth+1, $recipes);
        } elsif($filespec =~ m/\.json$/) {
            $self->read_bag_file($filespec, $recipes);
        }
    }
}

sub read_bag_file {
    my ($self, $filename, $recipes) = @_;

    open(my $catbag_f, '<:encoding(UTF-8)', $filename) ||
    die "Could not open '$filename': $!\n";

    return $self->read_bag_fh($catbag_f, $recipes);
}

sub read_bag_internal {
    my ($self, $recipes) = @_;

    {
        no warnings;
        if(tell(VC3::Builder::DATA) == -1) {
            return $recipes;
        }
    }

    my $catbag_f = *VC3::Builder::DATA;

    return $self->read_bag_fh($catbag_f, $recipes);
}


sub read_bag_fh {
    my ($self, $fh, $recipes) = @_;

    my $contents = do { local($/); <$fh> };
    close($fh);

    my $bag_raw; 
    eval { $bag_raw = JSON::Tiny::decode_json($contents); };
    if($@) {
        die "There was an error while decoding JSON file:\n$@\n";
    }

    if(ref($bag_raw) ne 'ARRAY') {
        $bag_raw = [ $bag_raw ];
    }

    for my $obj (@{$bag_raw}) {
        for my $package_name (keys %{$obj}) {

            my $pkg_raw = $obj->{$package_name};

            if(!$pkg_raw->{type} || $pkg_raw->{type} eq 'package') {
                $recipes->{package}{$package_name} = $pkg_raw;
            } elsif($pkg_raw->{type} eq 'operating-system') {
                $recipes->{op_sys}{$package_name} = $pkg_raw;
            } elsif($pkg_raw->{type} eq 'operating-system-distribution') {
                $recipes->{op_sys_distro}{$package_name} = $pkg_raw;
            } else {
                die "I don't know about a package type '" . $pkg_raw->{type} . "'\n";
            }
        }
    }

    return $recipes;
} 

sub decode_recipes {
    my ($self, $raw, $pkg_opts) = @_;

    my $recipes = {};

    for my $package_name (keys %{$raw}) {
        if(exists $pkg_opts->{$package_name}) {
            $raw->{$package_name}{options} = $pkg_opts->{$package_name};
            delete $pkg_opts->{$package_name};
        }

        my $pkg = VC3::Package->new($self, $package_name, $raw->{$package_name});
        $recipes->{$package_name} = $pkg;
    }

    return $recipes;
}

sub build_widget {
    my ($self, $widget, $sh_on_error, $force_rebuild, $ignore_locks) = @_;

    my $sys_label = $widget->source->type eq 'system' ? ' (from host)' : '';
    $self->say("processing for @{[$widget->package->name]}-" . $widget->version->normal . $sys_label);


    my $exit_status = 0;
    eval { $exit_status = -1; $exit_status = $widget->source->execute_recipe($force_rebuild, $ignore_locks) };

    if($exit_status) {
        $widget->process_error($sh_on_error, $English::EVAL_ERROR, $exit_status);
        exit 1;
    }

    return $exit_status;
}

sub dot_graph {
    my ($self, $dotname) = @_;
    return $self->plan->dot_graph($dotname);
}

sub to_parallel {
    my ($self, $dir, $make_jobs) = @_;

    my $abs_dir;
    if(file_name_is_absolute($dir)) {
        $abs_dir = $dir;
    } else {
        $abs_dir = catfile($self->home_dir, $dir);
    }

    my $dag_name       = 'dag';
    my $builder_name   = 'builder';
    my $local_database = 'recipes';

    File::Path::make_path($abs_dir);

    my $build_wrapper = catfile($abs_dir, 'build');
    open my $script_f, '>', "$build_wrapper" || die "Could not open '$build_wrapper' for writing: $!";
    print { $script_f } <<EOFF;
#! @{[$self->shell_executable]}
set -e

makeflow --shared-fs @{[$self->root_dir]} -r 5 $dag_name "\$@"

cat <<EOF

Parallel build mode complete. To run type:

VC3_ROOT=@{[$self->root_dir]}
VC3_DB=@{[catfile($abs_dir, $local_database)]}

$0 --database \\\${VC3_DB} --install \\\${VC3_ROOT} @{[map { "--require $_" } @{$self->plan->requirements}]}

EOF
EOFF

    close $script_f;
    chmod 0755, $build_wrapper;

    my $builder_path = catfile($abs_dir, $builder_name);
    copy($self->builder_path, $builder_path);
    chmod 0755, $builder_path;

    $self->plan->to_makeflow($abs_dir, $dag_name, $builder_name, $local_database, $make_jobs);

    $self->check_manual_requirements();
    $self->plan->prestage();
}

sub set_environment_variables {
    my ($self, $sh_f) = @_;

    my $env = $self->active_widgets_vars();

    my $expansion = {};

    for my $var (@{$self->environment_variables}) {
        $expansion->{$var->{name}} = [$var->{value}];
    }

    if($self->plan and $self->plan->order) {
        for my $wid (@{$self->plan->order}) {
            next unless $env->{$wid};
            $wid->consolidate_environment_variables($expansion);
        }
    }

    $expansion->{'PATH'} ||= [];
    $expansion->{'LD_LIBRARY_PATH'} ||= [];
    $expansion->{'MODULEPATH'} ||= [];

    # use default PATH:
    push @{$expansion->{'PATH'}},            $ENV{'PATH'}            || qw(/bin /usr/bin /usr/local/bin);
    push @{$expansion->{'LD_LIBRARY_PATH'}}, $ENV{'LD_LIBRARY_PATH'} || qw(/lib /usr/lib /usr/local/lib);
    push @{$expansion->{'MODULEPATH'}},      $ENV{'MODULEPATH'}      || ();

    for my $var_name (keys %{$expansion}) {
        my @values = $self->clean_variable_repetitions($expansion->{$var_name});

        eval { $expansion->{$var_name} = join(':', @values) };
        if($@) {
            warn("Environment variable '$var_name' was not explicitely set.\n");
        }
    }

    my @ordered = $self->order_variables($expansion);

    for my $var_name (@ordered) {
        my $value = $expansion->{$var_name};

        # if value already starts with quotes, don't add quotes.
        if($value =~ qr/^\s*("|')/) {
            print { $sh_f } "export $var_name=$value\n";
        } else {
            print { $sh_f } "export $var_name=\"$value\"\n";
        }
    }

    print { $sh_f } "\n";
}

sub clean_variable_repetitions {
    my ($self, $ref) = @_;

    my @values = @$ref;

    my %metric;
    my $count = 1;
    my $root = $self->root_dir;

    for my $v (@values) {
        if($v !~ m%^/(usr/(local/)?)?(bin|lib)$%) {
            $metric{$v} = $count;
        } elsif ($v =~ m%^$root%) {
            $metric{$v} = $count;
        } else {
            $metric{$v} = $count + @values;
        }
        $count++;
    }

    return sort { $metric{$a} <=> $metric{$b} } keys %metric;
}

sub order_variables {
    my ($self, $expansion) = @_;

    my @alpha = sort { $a cmp $b } keys %{$expansion};

    my $order = {};

    my $index = 1;
    for my $var (@alpha) {
        $order->{$var} = $index;
        $index++;
    }

    my $total_passes = 0;
    my $swap       = 1;

    while($swap) {
        $swap = 0;

        my @ordered = sort { ($order->{$a} <=> $order->{$b}) || ($a cmp $b) } keys %{$expansion};

        for my $var (@ordered) {
            my $value = $expansion->{$var};
            my @deps  = ($value =~ m/\$\{(\w+)\}/g);

            next unless @deps;

            my $org   = $order->{$var};
            my $nxt   = 1 + max(map { $order->{$_} || warn "Variable '$_' is not explicitely set.\n" } @deps);

            if($nxt > $org) {
                $swap++;
                $order->{$var} = $nxt;
            }
        }

        $total_passes++;
        carp "Cyclic dependency in environment variables." if $total_passes > @alpha;
    }

    my @ordered = sort { ($order->{$a} <=> $order->{$b}) || ($a cmp $b) } keys %{$expansion};
    return @ordered;
}


sub set_profile {
    my ($self, $profile_file, @command_and_args) = @_;

    my ($env_file, $prog_file, $wrap_file, $pay_file) = map { $profile_file . $_ } ('.env', '.prologue', '.wrapper', '.payload');
    
    # write to env file
    open(my $sh_f_env, '>', $env_file)
    || die "Could not open file $env_file $!";
    print { $sh_f_env } <<EOFP;
#! @{[$self->shell_executable]}

# don't load environment variables repeatedly (e.g., to not grow PATH at every shell)
if [ ! "\${VC3_ENV_TAG_GLOBAL}" = $$ ]
then

EOFP
    $self->set_environment_variables($sh_f_env);

    print { $sh_f_env } <<EOFP;
export VC3_ENV_TAG_GLOBAL=$$
fi

EOFP

    close($sh_f_env);

    # write to prologue file
    open(my $sh_f_prog, '>', $prog_file)
    || die "Could not open file $prog_file $!";
    print { $sh_f_prog } <<EOFP;
#! @{[$self->shell_executable]}

# don't source prologues at a shell that already sourced them.
if [ ! "\${VC3_ENV_TAG_LOCAL}" = $$ ]
then

EOFP

    for my $prog_line (@{$self->consolidate_prologue}) {
        print { $sh_f_prog } "$prog_line";
        print { $sh_f_prog } "\n";
    }

    print { $sh_f_prog } <<EOFP;

    VC3_ENV_TAG_LOCAL=$$
fi

EOFP

    # write to general profile
    open(my $sh_f, '>', "$profile_file")
    || die "Could not open file $profile_file $!";

    print { $sh_f } <<EOFP;
#! @{[$self->shell_executable]}

. $env_file
. $prog_file

EOFP
    close($sh_f);

    # write to payload file
    open(my $sh_f_pay, '>', $pay_file)
    || die "Could not open file $pay_file $!";

    print { $sh_f_pay } <<EOFP;
#! @{[$self->shell_executable]}

if [ "\${VC3_INSIDE_WRAPPER_SCRIPT}" != yes ]
then

    echo This script cannot be executed by itself.
    echo Run instead: ${wrap_file}
    exit 1
fi

# load profile for further interactive shells.
export ENV=$profile_file

# load profile if the exec below is not interactive
. $profile_file

EOFP

    print { $sh_f_pay } join(' ', 'exec', @command_and_args);
    print { $sh_f_pay } "\n";

    close($sh_f_pay);
    chmod 0755, $pay_file;

    # write to wrapper file
    open(my $sh_f_wrap, '>', "$wrap_file")
    || die "Could not open file $wrap_file $!";

    print { $sh_f_wrap } <<EOFP;
#! @{[$self->shell_executable]}

. $env_file

export VC3_INSIDE_WRAPPER_SCRIPT=yes
cd  "\${HOME}"

EOFP

    my @payload = ($pay_file);

    my $env = $self->active_widgets();
    if($self->plan and $self->plan->order) {
        for my $w (@{$self->plan->order}) {
            next unless $env->{$w};
            next unless $w->wrapper;

            my @wrap = @{$w->wrapper};
            my $braces_pos = first { $wrap[$_] eq '{}' } 0..$#wrap;

            if(defined($braces_pos)) {
                my @tmp = @payload;
                @payload = @wrap;
                splice @payload, $braces_pos, 1, @tmp;
            } else {
                @payload = (@wrap, @payload);
            }
        }
    }

    print { $sh_f_wrap } "exec @payload\n\n";

    close($sh_f_wrap);
    chmod 0755, $wrap_file;

    $self->add_builder_variable('VC3_SH_PROFILE_ENV',     $profile_file);
    $self->add_builder_variable('VC3_SH_PROFILE_WRAPPER', $wrap_file);
}

sub consolidate_prologue {
    my ($self) = @_;

    my $env = $self->active_widgets();

    my @progs = ();

    if($self->plan and $self->plan->order) {
        for my $w (@{$self->plan->order}) {
            next unless $env->{$w};

            if($w->prologue) {
                push @progs, @{$w->prologue};
            }
        }
    }

    return \@progs;
}

sub preserved_vars {
    my ($self) = @_;

    my %to_preserve;

    $to_preserve{HOME} = $self->home_dir;
    $to_preserve{USER} = $self->user_name;

    my @output;

    for my $var (keys %to_preserve) {
        push @output, "$var=$to_preserve{$var}";
    }

    return @output;
}


sub execute {
    my ($self, @command_and_args) = @_;

    $self->set_profile($self->sh_profile, @command_and_args);

    my $pid = fork();

    if($pid == 0) {
        my @args = (
            '/usr/bin/env',
            '-i',
            $self->preserved_vars(),
            $self->sh_profile . '.wrapper');

        POSIX::setpgid(0, 0);

        exec { $args[0] } @args;
        die 'Could not exec payload';
    } elsif($pid > 0) {

        close(STDIN);
        POSIX::setpgid($pid, $pid);

        if($self->{on_terminal}) {
            $self->bring_to_foreground($pid);
        }

        $self->{child_pid} = $pid;
        waitpid $pid, 0;
        my $status = $?;
        $self->{child_pid} = undef;

        return POSIX::WEXITSTATUS($status);
    } else {
        die 'Could not fork to exec payload: ' . $!;
    }
}

sub bring_to_foreground {
    my ($self, $groupid) = @_;

    $SIG{TTOU} = 'IGNORE';

    open my $term, '+<', '/dev/tty';
    return unless $term;

    POSIX::tcsetpgrp(fileno($term), $groupid) or die "Could not bring child to foreground: $!";

    close $term;
}

sub shell {
    my ($self, $payload) = @_;

    $payload |= $self->shell_executable;
    $self->set_profile($self->sh_profile, $payload);

    my $pid = open(my $input, '|-');
    if($pid == 0) {
        my @args = (
            '/usr/bin/env',
            '-i',
            $self->preserved_vars(),
            $self->sh_profile . '.wrapper');
        exec { $args[0] } @args;
        die 'Could not exec shell';
    } elsif($pid > 0) {
        $self->{child_pid} = $pid;
        # wait for this shell later.
    } else {
        die 'Could not fork to exec payload: ' . $!;
    }

    return ($pid, $input);
}

sub shell_user {
    my ($self) = @_;
    return $self->execute($self->shell_executable);
}

sub say {
    my ($self, @rest) = @_;

    return if($self->{silent_run} and $self->{silent_run} eq 'ALL');

    print( ('.' x ($self->{indent_level} || 0)), join(' ', @rest), "\n");
}

sub say_plan {
    my ($self, @rest) = @_;

    return if($self->{silent_run} and $self->{silent_run} eq 'plan');

    $self->say(@rest);
}

1;

