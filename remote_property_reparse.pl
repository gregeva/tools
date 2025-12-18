use strict;
use warnings;
use Text::CSV;
use Time::Piece;
use bytes;
use Getopt::Long qw(GetOptions);

# Enhanced Statistical Feature and Analysis Facilitation Requirements
# - read in entire file PropertyUpdates.log line by line populating the data structure so that it can later be re-sorted, have statistics generated, and be written to CSV
# - each line contains: server timestamp, thing name, property name, property timestamp (in milliseconds since epoch), value, quality
# - the data structure should be a hash of hashes where the first key is the thing name, the second key is the property name, the third keys are property time, value, and quality
# - there should be four parts to the execution: reading/parsing, data structure population, statistics generation, CSV writing
# - there are certain statistics which should be created and populated based on the previous data point and time combination: hasChanged, timeSinceLastChangeMs, totalPropertyChanges, totalThingPropertyChanges, byteSize
# - statistics generation should occur on the data structure sorted by thing name, then property name, then property timestamp ascending:
#     - temporary local variables should be used to hold previous value and timestamp for comparison
#     - the property timestamp should be converted from milliseconds since epoch to a human-readable format,
#     - the time since last value change in milliseconds should be calculated,
#     - should calculate total property changes for that property (for that thing) should be counted,
#     - should calculate total thing property changes,
#     - should calculate byte size of the value,
#     - should determine if the value has changed since the last recorded value for that property (for that thing)
#     - value should be truncated to 50 characters with "..." appended if longer than 50 characters
# - the CSV should contain: server timestamp, property timestamp (converted to human-readable format), thing name, property name, quality, hasChanged (boolean), timeSinceLastValueChangeMs, totalPropertyChanges, totalThingPropertyChanges, byteSize, value

# CLI options
my $input_file = 'PropertyUpdates.log';
my $output_file = 'output.csv';
my $flush_threshold = 1000; # number of distinct buffered properties before attempting flush
my $flush_window_ms = 60000; # flush properties whose latest timestamp is this far behind max seen
my $omit_same_values = 0;
my $truncate_after = 50; # characters

GetOptions(
    'input|i=s' => \$input_file,
    'output|o=s' => \$output_file,
    'flush-threshold|ft=i' => \$flush_threshold,
    'flush-window-ms|fw=i' => \$flush_window_ms,
    'omit-same-values|os' => \$omit_same_values,
    'truncate-after|ta=i' => \$truncate_after,
    'help|h' => sub {
        print "Usage: $0 [--input|-i <input_file>] [--output|-o <output_file>] [--flush-threshold|-ft <num>] [--flush-window-ms|-fw <ms>] [--omit-same-values|-os] [--truncate-after|-ta <chars>]\n";
        exit 0;
    },
) or die "Invalid options\n";

# Initialize CSV (streaming)
my $csv = Text::CSV->new({ sep_char => ';', binary => 1, eol => $/ });
open my $fh, '>', $output_file or die "Could not open $output_file: $!";
$csv->print($fh, ['serverTimestamp', 'propertyTimestamp', 'thingName', 'property', 'quality', 'hasChanged', 'timeSinceLastValueChangeS', 'byteSize', 'value']);

# Initialize data structure
my %data;
my $lines = 0;
my $malformed_count = 0;

my $buffered_props = 0;
my $max_prop_ts_ms_seen = 0;

# Read log file
open my $log, '<', $input_file or die "Could not open log file $input_file: $!";
while (my $line = <$log>) {
    # print "Processing line: $line" if $lines++ < 5;
    # "2025-12-12 15:59:38.006+0100";"";"AI_IOLINK_Pression_Eau_Urgence";"1765551575383";"5195";"GOOD"
    # "2025-12-12 15:59:38.006+0100";"";"AI_Pyrometre";"1765551576856";"1.5227141380310059";"GOOD"
    # "2025-12-12 15:59:38.006+0100";"";"AI_Vide_chambre";"1765551576858";"1.73614501953125";"GOOD"
    chomp $line;
    if ($line =~ /"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\+\d{4})";"(?<thing>.*?)";"(?<property>.*?)";"(?<timestamp>\d+)";"(?<value>.*?)";"(?<quality>.*?)"$/) {
        my $serverTimestamp = $1;
        my $propertyTimestampMs = $+{timestamp} + 0;
        my $propertyTimestamp;
        my $thing = $+{thing};
        my $property = $+{property};
        my $value = $+{value};
        my $quality = $+{quality};

        # Convert milliseconds since epoch to human-readable timestamp using Time::Piece
        if (defined $propertyTimestampMs && $propertyTimestampMs =~ /^\d+$/) {
            my $t_sec = int($propertyTimestampMs / 1000);
            my $ms = $propertyTimestampMs % 1000;
            my $tp = Time::Piece->localtime($t_sec);
            $propertyTimestamp = $tp->strftime("%Y-%m-%d %H:%M:%S") . sprintf(".%03d", $ms) . $tp->strftime("%z");
        }

        # Track max seen timestamp
        $max_prop_ts_ms_seen = $propertyTimestampMs if $propertyTimestampMs > $max_prop_ts_ms_seen;

        # Initialize container for this thing/property if needed
        if (!exists $data{$thing}{$property}) {
            $data{$thing}{$property} = [];
            $buffered_props++;
        }

        # Push the parsed entry into history for this property
        push @{ $data{$thing}{$property} }, {
            server_ts => $serverTimestamp,
            prop_ts_ms => $propertyTimestampMs,
            prop_ts_hr => $propertyTimestamp,
            value => $value,
            quality => $quality,
            line_no => $.,
        };

        # If buffered properties exceed threshold, attempt to flush old properties
        if ($buffered_props > $flush_threshold) {
            _attempt_flush_old_properties(\%data, \$buffered_props, $max_prop_ts_ms_seen, $flush_window_ms, $csv, $fh);
        }
    }
    else {
        $malformed_count++;
        next;
    }
}

close $log;

# After reading all input, process remaining properties
for my $thing (sort keys %data) {
    for my $property (sort keys %{ $data{$thing} }) {
        _process_and_write_property($thing, $property, $data{$thing}{$property}, $csv, $fh);
        delete $data{$thing}{$property};
        $buffered_props--;
    }
}

close $fh;

print "Processing complete. Output saved to $output_file\n";
print "Malformed lines encountered: $malformed_count\n" if $malformed_count > 0;

### Subroutines
sub _process_and_write_property {
    my ($thing, $property, $entries, $csv_obj, $filehandle) = @_;

    # sort entries by prop_ts_ms ascending
    my @sorted = sort { $a->{prop_ts_ms} <=> $b->{prop_ts_ms} } @{$entries};

    my $prev_value;
    my $prev_ts_ms;

    for my $e (@sorted) {
        my $server_ts = $e->{server_ts};
        my $prop_ts_hr = $e->{prop_ts_hr} // '';
        my $value = $e->{value};
        my $quality = $e->{quality} // '';

        my $hasChanged = 1;
        if (defined $prev_value && $prev_value eq $value) {
            $hasChanged = 0;
        }

        my $time_since_s = '';
        if (defined $prev_ts_ms) {
            $time_since_s = sprintf("%.3f", ($e->{prop_ts_ms} - $prev_ts_ms) / 1000.0);
        }

        my $byte_size = bytes::length($value);

        # truncate value to 50 characters for CSV output
        my $out_value = $value;
        if ($omit_same_values && $hasChanged == 0) {
            # skip writing the actual value if it hasn't changed
            $out_value = '';
        } elsif (length($out_value) > $truncate_after ) {
            $out_value = substr($out_value, 0, $truncate_after ) . ' ... (trunc.)';
        }

        $csv_obj->print($filehandle, [$server_ts, $prop_ts_hr, $thing, $property, $quality, $hasChanged, $time_since_s, $byte_size, $out_value]);

        $prev_value = $value;
        $prev_ts_ms = $e->{prop_ts_ms};
    }
}

sub _attempt_flush_old_properties {
    my ($data_ref, $buffered_ref, $max_seen, $window_ms, $csv_obj, $filehandle) = @_;

    # find properties whose latest timestamp is older than max_seen - window_ms
    my @to_flush;
    for my $thing (sort keys %{$data_ref}) {
        for my $property (keys %{ $data_ref->{$thing} }) {
            my $entries = $data_ref->{$thing}{$property};
            next unless @$entries;
            my $latest = 0;
            for my $e (@$entries) { $latest = $e->{prop_ts_ms} if $e->{prop_ts_ms} > $latest }
            if ($latest <= $max_seen - $window_ms) {
                push @to_flush, [$thing, $property];
            }
        }
    }

    # flush collected properties (up to half the buffer to relieve memory)
    my $target = int(@to_flush / 2) || scalar(@to_flush);
    for my $i (0 .. $target-1) {
        my ($thing, $property) = @{ $to_flush[$i] };
        _process_and_write_property($thing, $property, $data_ref->{$thing}{$property}, $csv_obj, $filehandle);
        delete $data_ref->{$thing}{$property};
        $$buffered_ref--;
    }
}

