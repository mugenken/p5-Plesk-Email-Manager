use 5.006;
use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'Plesk::Email::Manager',
    license             => 'perl',
    dist_author         => q{Matthias Krull <<m.krull@rapidrabbit.de>>},
    dist_version_from   => 'lib/Plesk/Email/Manager.pm',
    build_requires => {
        'Test::More' => 0,
    },
    requires => {
        'perl' => 5.006,
    },
    add_to_cleanup      => [ 'Plesk-Email-Manager-*' ],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
