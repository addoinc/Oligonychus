package PostTaskFactory;

use strict;
use warnings;

our $VERSION = '0.01';

use base 'Exporter';

our @EXPORT = qw(get_posttask);

sub get_posttask {
        my %param = @_;

        my $p_obj;
        my $ch_task;

        if ( $param{'channel'} eq 'HBO' ) {
                require AzTask::HBOPostTask;
                $p_obj = AzTask::HBOPostTask->new(
                        schedules_csv => $param{'schedules_csv'},
			channel => $param{'channel'},
                );
                $ch_task = 'AzTask::HBOPostTask';
	} elsif ( $param{'channel'} eq 'Star' ) {
                require AzTask::StarPostTask;
                $p_obj = AzTask::StarPostTask->new(
			schedules_csv => $param{'schedules_csv'},
			channel => $param{'channel'},
		);
                $ch_task = 'AzTask::StarPostTask';
	} else {
		require AzTask::TaskBase;
                $p_obj = AzTask::TaskBase->New();;
	}

        no strict 'refs';
        push @{$ch_task.'::ISA'}, 'AzTask::TaskBase';
        use strict;
        return bless $p_obj, $ch_task;
};

1;
