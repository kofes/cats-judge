package CATS::Judge::Local;

use strict;
use warnings;

use POSIX qw(strftime);

use CATS::Constants;
use CATS::Problem::Parser;
use CATS::Problem::ImportSource;
use CATS::Problem::Source::Zip;
use CATS::Problem::Source::PlainFiles;

use CATS::Utils qw(split_fname);

use base qw(CATS::Judge::Base);

my $pid;

sub auth {
    my ($self) = @_;
    return;
}

sub get_problem_id {
    $pid ||= Digest::MD5::md5_hex(Encode::encode_utf8($_[0]->{parser}{problem}{description}{title}))
}

sub update_state {
    my ($self) = @_;
    0;
}

sub set_request_state {
    my ($self, $req, $state, %p) = @_;
}

sub select_request {
    my ($self, $supported_DEs) = @_;
    -f $self->{problem} or -d $self->{problem} or die 'Bad problem';

    my $source = -f $self->{problem} ?
        CATS::Problem::Source::Zip->new($self->{problem}, $self->{logger}) :
        CATS::Problem::Source::PlainFiles->new(dir => $self->{problem}, logger => $self->{logger});

    my $import_source = $self->{db} ?
        CATS::Problem::ImportSource::DB->new :
        CATS::Problem::ImportSource::Local->new(modulesdir => $self->{modulesdir});

    $self->{parser} = CATS::Problem::Parser->new(
        id_gen => \&CATS::DB::new_id,
        source => $source,
        import_source => $import_source,
    );

    eval { $self->{parser}->parse; };
    die "Problem parsing failed: $@" if $@;

    open FILE, $self->{solution} or die "Couldn't open file: $!";
    {
        id => 0,
        problem_id => $self->get_problem_id,
        contest_id => 0,
        state => 1,
        is_jury => 0,
        run_all_tests => 1,
        status => $cats::problem_st_ready,
        fname => $self->{solution},
        src => (join '', <FILE>),
        de_id => $self->{de},
    };
}

sub save_log_dump {
    my ($self, $req, $dump) = @_;
}

sub set_DEs {
    my ($self, $cfg_de) = @_;
    while (my ($key, $value) = each %$cfg_de) {
        $value->{code} = $value->{id} = $key;
    }
    $self->{supported_DEs} = $cfg_de;
}

sub set_def_DEs {
    my ($self, $cfg_def_DEs) = @_;
    $self->{def_DEs} = $cfg_def_DEs;
    $self->{de} = $self->auto_detect_de($self->{solution}) if !$self->{de};
}

sub pack_problem_source
{
    my ($self, %p) = @_;
    use Carp;
    my $s = $p{source_object} or confess;
    {
        id => defined $s->{id} ? $s->{id} : undef,
        problem_id => $self->get_problem_id,
        code => $s->{de_code},
        de_id => defined $s->{de_code} ? $self->{supported_DEs}{$s->{de_code}}{id} || -1 : -1,
        src => $s->{src},
        stype => $p{source_type},
        fname => $s->{path},
        input_file => $s->{inputFile},
        output_file => $s->{outputFile},
        guid => $s->{guid},
        time_limit => $s->{time_limit},
        memory_limit => $s->{memory_limit},
    }
}

sub auto_detect_de {
    my ($self, $fname) = @_;
    my (undef, undef, undef, undef, $ext) = split_fname($fname);
    defined $self->{def_DEs}{$ext} or die "Can not auto-detect DE for file $fname";
    $self->{def_DEs}{$ext};
}

sub ensure_de {
    my ($self, $source) = @_;
    $source->{de_id} = $source->{code} = $self->auto_detect_de($source->{fname}) if !$source->{code};
    exists $self->{supported_DEs}{$source->{code}}
        or die "Unsupported de: $_->{code} for source '$source->{fname}'";
}

sub get_problem_sources {
    my ($self, $pid) = @_;

    my $problem = $self->{parser}->{problem};
    my $problem_sources = [];

    if (my $c = $problem->{checker}) {
        push @$problem_sources, $self->pack_problem_source(
            source_object => $c, source_type => CATS::Problem::checker_type_names->{$c->{style}},
        );
    }

    for (@{$problem->{validators}}) {
        push @$problem_sources, $self->pack_problem_source(
            source_object => $_, source_type => $cats::validator,
        );
    }

    for(@{$problem->{generators}}) {
        push @$problem_sources, $self->pack_problem_source(
            source_object => $_, source_type => $cats::generator,
        );
    }

    for(@{$problem->{solutions}}) {
        push @$problem_sources, $self->pack_problem_source(
            source_object => $_, source_type => $_->{checkup} ? $cats::adv_solution : $cats::solution,
        );
    }

    for (@{$problem->{modules}}) {
        push @$problem_sources, $self->pack_problem_source(
            source_object => $_, source_type => $_->{type_code},
        );
    }

    for my $source ($self->{parser}{import_source}->get_sources_info($problem->{imports})) {
        $source->{problem_id} = $self->get_problem_id;
        $source->{de_id} = $self->{supported_DEs}{$source->{code}}{id};
        push @$problem_sources, $source;
    }

    $self->ensure_de($_) for @$problem_sources;

    [ @$problem_sources ];
}

sub delete_req_details {
    my ($self, $req_id) = @_;
}

sub insert_req_details {
    my ($self, $p) = @_;
}

sub get_problem_tests {
    my ($self, $pid) = @_;
    my $tests = [];
    for (sort { $a->{rank} <=> $b->{rank} } values %{$self->{parser}{problem}->{tests}}) {
        push @$tests, {
            generator_id => $_->{generator_id},
            rank => $_->{rank},
            param => $_->{param},
            std_solution_id => $_->{std_solution_id},
            in_file => $_->{in_file},
            out_file => $_->{out_file},
            gen_group => $_->{gen_group}
        };
    }
    [ @$tests ];
}

sub get_problem {
    my ($self, $pid) = @_;
    die "no parser" if !defined $self->{parser};
    my $p = $self->{parser}{problem}{description};
    {
        id => $self->get_problem_id,
        title => $p->{title},
        upload_date => strftime(
            $CATS::Judge::Base::timestamp_format, localtime $self->{parser}->{source}->last_modified),
        time_limit => $p->{time_limit},
        memory_limit => $p->{memory_limit},
        input_file => $p->{input_file},
        output_file => $p->{output_file},
        std_checker => $p->{std_checker},
        contest_id => 0
    };
}

sub is_problem_uptodate {
    my ($self, $pid, $cached_date) = @_;
    my $upload_date = $self->get_problem($pid)->{upload_date};
    # date format: dd-mm-yyyy hh:mm:ss -> yyyy-mm-dd hh:mm:ss
    $upload_date =~ m/^(\d+)-(\d+)-(\d+)\s(.+)$/ or return 0;
    $upload_date = "$3-$2-$1 $4";
    return $upload_date le $cached_date;
}

sub get_testset {
    my ($self, $rid, $update) = @_;
    $self->{testset} or return map { $_->{rank} => undef } values %{$self->{parser}{problem}{tests}};

    my @all_tests = map { $_->{rank} } values %{$self->{parser}{problem}{tests}};
    my %tests = %{CATS::Testset::parse_test_rank($self->{parser}{problem}{testsets}, $self->{testset})};
    map { exists $tests{$_} ? ($_ => $tests{$_}) : () } @all_tests;
}

1;
