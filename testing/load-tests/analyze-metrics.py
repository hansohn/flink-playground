#!/usr/bin/env python3
"""
Flink Memory Load Test Analysis Tool

This script analyzes metrics collected during load tests and generates reports.

Usage:
    python3 analyze-metrics.py --prometheus-url http://localhost:9090 --duration 300

Requirements:
    pip install requests prometheus-api-client pandas matplotlib
"""

import argparse
import sys
import time
from datetime import datetime, timedelta
from typing import Dict, List
import json

try:
    import requests
    from prometheus_api_client import PrometheusConnect
    import pandas as pd
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
except ImportError as e:
    print(f"Error: Missing required dependency: {e}")
    print("Install dependencies with:")
    print("  pip install requests prometheus-api-client pandas matplotlib")
    sys.exit(1)


class FlinkMetricsAnalyzer:
    """Analyzes Flink metrics from Prometheus"""

    def __init__(self, prometheus_url: str):
        self.prom = PrometheusConnect(url=prometheus_url, disable_ssl=True)

    def query_metric(self, query: str, start_time: datetime, end_time: datetime, step: str = "10s") -> pd.DataFrame:
        """Query a metric from Prometheus and return as DataFrame"""
        try:
            result = self.prom.custom_query_range(
                query=query,
                start_time=start_time,
                end_time=end_time,
                step=step
            )

            if not result:
                return pd.DataFrame()

            # Convert to DataFrame
            data = []
            for item in result:
                metric_labels = item['metric']
                for timestamp, value in item['values']:
                    data.append({
                        'timestamp': datetime.fromtimestamp(timestamp),
                        'value': float(value),
                        **metric_labels
                    })

            return pd.DataFrame(data)

        except Exception as e:
            print(f"Error querying metric: {e}")
            return pd.DataFrame()

    def analyze_memory(self, start_time: datetime, end_time: datetime) -> Dict:
        """Analyze memory metrics"""
        print("Analyzing memory metrics...")

        results = {}

        # Heap memory usage
        heap_used = self.query_metric(
            'flink_taskmanager_Status_JVM_Memory_Heap_Used',
            start_time, end_time
        )
        heap_max = self.query_metric(
            'flink_taskmanager_Status_JVM_Memory_Heap_Max',
            start_time, end_time
        )

        if not heap_used.empty:
            results['heap_used_avg'] = heap_used['value'].mean()
            results['heap_used_max'] = heap_used['value'].max()
            results['heap_used_min'] = heap_used['value'].min()

        if not heap_max.empty:
            results['heap_max'] = heap_max['value'].iloc[0]

        # Managed memory (RocksDB)
        managed_used = self.query_metric(
            'flink_taskmanager_Status_Flink_Memory_Managed_Used',
            start_time, end_time
        )

        if not managed_used.empty:
            results['managed_memory_avg'] = managed_used['value'].mean()
            results['managed_memory_max'] = managed_used['value'].max()

        return results

    def analyze_gc(self, start_time: datetime, end_time: datetime) -> Dict:
        """Analyze garbage collection metrics"""
        print("Analyzing GC metrics...")

        results = {}

        # GC time
        gc_time = self.query_metric(
            'rate(flink_taskmanager_Status_JVM_GarbageCollector_G1_Young_Generation_Time[1m])',
            start_time, end_time
        )

        if not gc_time.empty:
            results['gc_time_avg'] = gc_time['value'].mean()
            results['gc_time_max'] = gc_time['value'].max()

        # GC count
        gc_count = self.query_metric(
            'rate(flink_taskmanager_Status_JVM_GarbageCollector_G1_Young_Generation_Count[1m])',
            start_time, end_time
        )

        if not gc_count.empty:
            results['gc_count_avg'] = gc_count['value'].mean() * 60  # per minute
            results['gc_count_max'] = gc_count['value'].max() * 60

        return results

    def analyze_checkpoints(self, start_time: datetime, end_time: datetime) -> Dict:
        """Analyze checkpoint metrics"""
        print("Analyzing checkpoint metrics...")

        results = {}

        # Checkpoint duration
        duration = self.query_metric(
            'flink_jobmanager_job_lastCheckpointDuration',
            start_time, end_time
        )

        if not duration.empty:
            results['checkpoint_duration_avg'] = duration['value'].mean()
            results['checkpoint_duration_max'] = duration['value'].max()

        # Checkpoint size
        size = self.query_metric(
            'flink_jobmanager_job_lastCheckpointSize',
            start_time, end_time
        )

        if not size.empty:
            results['checkpoint_size_avg'] = size['value'].mean()
            results['checkpoint_size_max'] = size['value'].max()

        # Checkpoint success/failure
        completed = self.query_metric(
            'flink_jobmanager_job_numberOfCompletedCheckpoints',
            start_time, end_time
        )
        failed = self.query_metric(
            'flink_jobmanager_job_numberOfFailedCheckpoints',
            start_time, end_time
        )

        if not completed.empty:
            results['checkpoints_completed'] = int(completed['value'].iloc[-1])
        if not failed.empty:
            results['checkpoints_failed'] = int(failed['value'].iloc[-1])

        return results

    def analyze_throughput(self, start_time: datetime, end_time: datetime) -> Dict:
        """Analyze throughput metrics"""
        print("Analyzing throughput metrics...")

        results = {}

        # Records in per second
        records_in = self.query_metric(
            'rate(flink_taskmanager_job_task_numRecordsInPerSecond[1m])',
            start_time, end_time
        )

        if not records_in.empty:
            results['throughput_avg'] = records_in['value'].mean()
            results['throughput_max'] = records_in['value'].max()
            results['throughput_min'] = records_in['value'].min()

        return results

    def analyze_backpressure(self, start_time: datetime, end_time: datetime) -> Dict:
        """Analyze backpressure metrics"""
        print("Analyzing backpressure metrics...")

        results = {}

        backpressure = self.query_metric(
            'flink_taskmanager_job_task_backPressuredTimeMsPerSecond',
            start_time, end_time
        )

        if not backpressure.empty:
            # Convert to fraction (0-1)
            backpressure['value'] = backpressure['value'] / 1000
            results['backpressure_avg'] = backpressure['value'].mean()
            results['backpressure_max'] = backpressure['value'].max()

        return results

    def generate_plots(self, start_time: datetime, end_time: datetime, output_dir: str):
        """Generate visualization plots"""
        print(f"Generating plots to {output_dir}...")

        fig, axes = plt.subplots(3, 2, figsize=(15, 12))
        fig.suptitle('Flink Memory Load Test Results', fontsize=16)

        # 1. Heap Memory Usage
        heap_used = self.query_metric('flink_taskmanager_Status_JVM_Memory_Heap_Used', start_time, end_time)
        heap_max = self.query_metric('flink_taskmanager_Status_JVM_Memory_Heap_Max', start_time, end_time)

        if not heap_used.empty:
            for host in heap_used['host'].unique():
                host_data = heap_used[heap_used['host'] == host]
                axes[0, 0].plot(host_data['timestamp'], host_data['value'] / (1024**3), label=f'Used - {host}')

            if not heap_max.empty:
                for host in heap_max['host'].unique():
                    host_data = heap_max[heap_max['host'] == host]
                    axes[0, 0].plot(host_data['timestamp'], host_data['value'] / (1024**3),
                                   label=f'Max - {host}', linestyle='--')

            axes[0, 0].set_title('Heap Memory (GB)')
            axes[0, 0].set_xlabel('Time')
            axes[0, 0].set_ylabel('Memory (GB)')
            axes[0, 0].legend()
            axes[0, 0].grid(True)

        # 2. Managed Memory (RocksDB)
        managed = self.query_metric('flink_taskmanager_Status_Flink_Memory_Managed_Used', start_time, end_time)

        if not managed.empty:
            for host in managed['host'].unique():
                host_data = managed[managed['host'] == host]
                axes[0, 1].plot(host_data['timestamp'], host_data['value'] / (1024**3), label=host)

            axes[0, 1].set_title('Managed Memory - RocksDB (GB)')
            axes[0, 1].set_xlabel('Time')
            axes[0, 1].set_ylabel('Memory (GB)')
            axes[0, 1].legend()
            axes[0, 1].grid(True)

        # 3. GC Time
        gc_time = self.query_metric(
            'rate(flink_taskmanager_Status_JVM_GarbageCollector_G1_Young_Generation_Time[1m])',
            start_time, end_time
        )

        if not gc_time.empty:
            for host in gc_time['host'].unique():
                host_data = gc_time[gc_time['host'] == host]
                axes[1, 0].plot(host_data['timestamp'], host_data['value'], label=host)

            axes[1, 0].set_title('GC Time (ms/s)')
            axes[1, 0].set_xlabel('Time')
            axes[1, 0].set_ylabel('Time (ms)')
            axes[1, 0].legend()
            axes[1, 0].grid(True)

        # 4. Checkpoint Duration
        checkpoint_duration = self.query_metric('flink_jobmanager_job_lastCheckpointDuration', start_time, end_time)

        if not checkpoint_duration.empty:
            axes[1, 1].plot(checkpoint_duration['timestamp'], checkpoint_duration['value'])
            axes[1, 1].set_title('Checkpoint Duration (ms)')
            axes[1, 1].set_xlabel('Time')
            axes[1, 1].set_ylabel('Duration (ms)')
            axes[1, 1].grid(True)

        # 5. Throughput
        throughput = self.query_metric('rate(flink_taskmanager_job_task_numRecordsInPerSecond[1m])', start_time, end_time)

        if not throughput.empty:
            for task in throughput['task_name'].unique():
                task_data = throughput[throughput['task_name'] == task]
                axes[2, 0].plot(task_data['timestamp'], task_data['value'], label=task)

            axes[2, 0].set_title('Throughput (records/s)')
            axes[2, 0].set_xlabel('Time')
            axes[2, 0].set_ylabel('Records/s')
            axes[2, 0].legend()
            axes[2, 0].grid(True)

        # 6. Backpressure
        backpressure = self.query_metric('flink_taskmanager_job_task_backPressuredTimeMsPerSecond', start_time, end_time)

        if not backpressure.empty:
            backpressure['value'] = backpressure['value'] / 1000  # Convert to fraction
            for task in backpressure['task_name'].unique():
                task_data = backpressure[backpressure['task_name'] == task]
                axes[2, 1].plot(task_data['timestamp'], task_data['value'], label=task)

            axes[2, 1].set_title('Backpressure (0=none, 1=full)')
            axes[2, 1].set_xlabel('Time')
            axes[2, 1].set_ylabel('Backpressure')
            axes[2, 1].legend()
            axes[2, 1].grid(True)

        plt.tight_layout()
        plt.savefig(f'{output_dir}/metrics-visualization.png', dpi=300, bbox_inches='tight')
        print(f"Plot saved to {output_dir}/metrics-visualization.png")


def main():
    parser = argparse.ArgumentParser(description='Analyze Flink memory load test results')
    parser.add_argument('--prometheus-url', default='http://localhost:9090',
                       help='Prometheus server URL')
    parser.add_argument('--duration', type=int, default=300,
                       help='Test duration in seconds (looks back this far)')
    parser.add_argument('--output-dir', default='load-test-analysis',
                       help='Output directory for reports')

    args = parser.parse_args()

    # Calculate time range
    end_time = datetime.now()
    start_time = end_time - timedelta(seconds=args.duration)

    print(f"Analyzing metrics from {start_time} to {end_time}")
    print(f"Prometheus URL: {args.prometheus_url}")
    print()

    # Create analyzer
    analyzer = FlinkMetricsAnalyzer(args.prometheus_url)

    # Run analyses
    memory_results = analyzer.analyze_memory(start_time, end_time)
    gc_results = analyzer.analyze_gc(start_time, end_time)
    checkpoint_results = analyzer.analyze_checkpoints(start_time, end_time)
    throughput_results = analyzer.analyze_throughput(start_time, end_time)
    backpressure_results = analyzer.analyze_backpressure(start_time, end_time)

    # Print results
    print("\n" + "=" * 60)
    print("ANALYSIS RESULTS")
    print("=" * 60)

    print("\nMemory:")
    for key, value in memory_results.items():
        if 'heap' in key or 'managed' in key:
            print(f"  {key}: {value / (1024**3):.2f} GB")
        else:
            print(f"  {key}: {value:.2f}")

    print("\nGarbage Collection:")
    for key, value in gc_results.items():
        print(f"  {key}: {value:.2f}")

    print("\nCheckpoints:")
    for key, value in checkpoint_results.items():
        if 'size' in key:
            print(f"  {key}: {value / (1024**2):.2f} MB")
        elif 'duration' in key:
            print(f"  {key}: {value:.2f} ms")
        else:
            print(f"  {key}: {value}")

    print("\nThroughput:")
    for key, value in throughput_results.items():
        print(f"  {key}: {value:.2f} records/s")

    print("\nBackpressure:")
    for key, value in backpressure_results.items():
        print(f"  {key}: {value:.2%}")

    # Generate visualizations
    import os
    os.makedirs(args.output_dir, exist_ok=True)
    analyzer.generate_plots(start_time, end_time, args.output_dir)

    # Save JSON report
    all_results = {
        'test_info': {
            'start_time': start_time.isoformat(),
            'end_time': end_time.isoformat(),
            'duration_seconds': args.duration
        },
        'memory': memory_results,
        'gc': gc_results,
        'checkpoints': checkpoint_results,
        'throughput': throughput_results,
        'backpressure': backpressure_results
    }

    report_file = f'{args.output_dir}/analysis-report.json'
    with open(report_file, 'w') as f:
        json.dump(all_results, f, indent=2)

    print(f"\nDetailed report saved to: {report_file}")
    print(f"Visualization saved to: {args.output_dir}/metrics-visualization.png")


if __name__ == '__main__':
    main()
