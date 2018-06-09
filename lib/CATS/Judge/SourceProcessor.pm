package CATS::Judge::SourceProcessor;

use strict;
use warnings;

use File::Spec;

use CATS::Constants;
use CATS::Judge::Config ();

*apply_params = *CATS::Judge::Config::apply_params;

sub new {
    my ($class) = shift;
    my $self = { @_ };
    bless $self, $class;
    $self->cfg && $self->fu && $self->log && $self->sp or die;

    $self->{de_idx} = {};
    $self->{de_idx}->{$_->{id}} = $_ for values %{$self->cfg->DEs};

    $self;
}

sub cfg { $_[0]->{cfg} }
sub fu { $_[0]->{fu} }
sub log { $_[0]->{log} }
sub sp { $_[0]->{sp} }

sub property {
    my ($self, $name, $de_id) = @_;
    exists $self->{de_idx}->{$de_id} or die "undefined de_id: $de_id";
    $self->{de_idx}->{$de_id}->{$name};
}

# ps: { de_id, code }
sub require_property {
    my ($self, $name, $ps) = @_;
    $self->property($name, $ps->{de_id}) ||
        $self->log->msg("No '%s' action for DE: %s\n",
            $name, $ps->{code} // 'id=' . $ps->{de_id});
}

# sources: [ { de_id, code } ]
sub unsupported_DEs {
    my ($self, $sources) = @_;
    map { $_->{code} => 1 } grep !exists $self->{de_idx}->{$_->{de_id}}, @$sources;
}

# source: { de_id, name_parts }
# => undef | $cats::st_testing | $cats::st_compilation_error
sub compile {
    my ($self, $source, $opt) = @_;
    my $de_id = $source->{de_id} or die;
    my $name_parts = $source->{name_parts} or die;
    my $de = $self->{de_idx}->{$de_id} or die "undefined de_id: $de_id";

    defined $de->{compile} or return;
    # Empty string -> no compilation needed.
    $de->{compile} or return $cats::st_testing;

    my %env;
    if (my $add_path = $self->property(compile_add_path => $de_id)) {
        my $path = apply_params($add_path, { %$name_parts, PATH => $ENV{PATH} });
        %env = (env => { PATH => $path });
    }
    my $sp_report = $self->sp->run_single({
        ($opt->{section} ? (section => $cats::log_section_compile) : ()),
        encoding => $de->{encoding},
        %env },
        apply_params($de->{compile}, $name_parts)
    ) or return;
    $sp_report->tr_ok or return;

    my $ok = $sp_report->{exit_code} == 0;

    if ($ok && $de->{compile_error_flag}) {
        my $re = qr/\Q$cats::log_section_compile\E\n\Q$de->{compile_error_flag}\E/m;
        $ok = 0 if $self->log->get_dump =~ $re;
    }

    if ($ok && $de->{runfile}) {
        my $fn = apply_params($de->{runfile}, $name_parts);
        -f File::Spec->catfile($self->cfg->rundir, $fn) or do {
            $self->log->msg("Runfile '$fn' not created\n");
            $ok = 0;
        };
    }

    $ok or $self->log->msg("compilation error\n");
    $ok ? $cats::st_testing : $cats::st_compilation_error;
}

sub get_limits {
    my ($self, $ps, $problem) = @_;
    $problem //= {};
    my %res = map { $_ => $ps->{"req_$_"} || $ps->{"cp_$_"} || $ps->{$_} || $problem->{$_} }
        @cats::limits_fields;
    $res{deadline} = $res{time_limit}
        if $res{time_limit} && (!defined $ENV{SP_DEADLINE} || $res{time_limit} > $ENV{SP_DEADLINE});
    if ($res{memory_limit} && $ps->{de_id}) {
        $res{memory_limit} += $self->property(memory_handicap => $ps->{de_id}) // 0;
    }
    $res{write_limit} = $res{write_limit} . 'B' if $res{write_limit};
    %res;
}

1;
