package com.example.flink;

import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.functions.MapFunction;
import org.apache.flink.api.common.functions.RichMapFunction;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.api.common.state.ValueState;
import org.apache.flink.api.common.state.ValueStateDescriptor;
import org.apache.flink.api.common.time.Time;
import org.apache.flink.api.java.tuple.Tuple2;
import org.apache.flink.configuration.Configuration;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.DataStreamSource;
import org.apache.flink.streaming.api.datastream.SingleOutputStreamOperator;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.source.RichParallelSourceFunction;
import org.apache.flink.streaming.api.functions.windowing.ProcessWindowFunction;
import org.apache.flink.streaming.api.windowing.assigners.TumblingProcessingTimeWindows;
import org.apache.flink.streaming.api.windowing.time.TimeWindow;
import org.apache.flink.util.Collector;

import java.util.Random;

/**
 * Flink job designed to stress-test autoscaling:
 * - Synthetic infinite event source with configurable rate
 * - CPU-heavy map step
 * - Keyed tumbling windows with state
 */
public class AutoscalingLoadJob {

    public static void main(String[] args) throws Exception {
        // Configurable params via args or environment
        int eventsPerSecondPerParallelSubtask = getIntArg(args, "--eps", 2000);
        int cpuWorkIterations = getIntArg(args, "--cpu-iterations", 10_000);
        int numKeys = getIntArg(args, "--keys", 128);
        int windowSeconds = getIntArg(args, "--window-seconds", 30);

        System.out.printf(
            "Starting AutoscalingLoadJob with eps=%d, cpu-iterations=%d, keys=%d, window=%ds%n",
            eventsPerSecondPerParallelSubtask, cpuWorkIterations, numKeys, windowSeconds
        );

        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // Optional: enable checkpoints so state grows and is snapshotted
        env.enableCheckpointing(30_000, CheckpointingMode.EXACTLY_ONCE);
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(5_000);

        // 1) Synthetic load source
        DataStreamSource<LoadEvent> source =
                env.addSource(new SyntheticLoadSource(eventsPerSecondPerParallelSubtask, numKeys))
                   .name("synthetic-load-source")
                   .uid("synthetic-load-source");

        // 2) CPU-heavy map
        SingleOutputStreamOperator<LoadEvent> heavyMapped =
                source.map(new CpuHeavyMap(cpuWorkIterations))
                      .name("cpu-heavy-map")
                      .uid("cpu-heavy-map");

        // 3) Keyed tumbling window with simple stateful aggregation
        heavyMapped
                .keyBy(e -> e.key)
                .window(TumblingProcessingTimeWindows.of(Time.seconds(windowSeconds)))
                .process(new CountingWindowFunction())
                .name("keyed-window-agg")
                .uid("keyed-window-agg")
                // 4) Sink: discard / log aggregated stats
                .map((MapFunction<Tuple2<String, Long>, String>) value ->
                        "Window result: key=" + value.f0 + " count=" + value.f1)
                .name("to-string")
                .print()
                .name("stdout-sink");

        env.execute("Flink Autoscaling Load Job");
    }

    private static int getIntArg(String[] args, String name, int defaultValue) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals(name)) {
                try {
                    return Integer.parseInt(args[i + 1]);
                } catch (NumberFormatException ignored) {
                }
            }
        }
        String envName = name.replace("-", "").toUpperCase(); // e.g. --eps -> EPS
        String envVal = System.getenv(envName);
        if (envVal != null) {
            try {
                return Integer.parseInt(envVal);
            } catch (NumberFormatException ignored) {
            }
        }
        return defaultValue;
    }

    // POJO for events
    public static class LoadEvent {
        public String key;
        public long timestamp;
        public double payload;

        @SuppressWarnings("unused")
        public LoadEvent() {}

        public LoadEvent(String key, long timestamp, double payload) {
            this.key = key;
            this.timestamp = timestamp;
            this.payload = payload;
        }
    }

    /**
     * Synthetic parallel source that emits events at a fixed rate per subtask.
     */
    public static class SyntheticLoadSource extends RichParallelSourceFunction<LoadEvent> {

        private volatile boolean running = true;
        private final int eventsPerSecond;
        private final int numKeys;

        public SyntheticLoadSource(int eventsPerSecond, int numKeys) {
            this.eventsPerSecond = eventsPerSecond;
            this.numKeys = numKeys;
        }

        @Override
        public void run(SourceContext<LoadEvent> ctx) throws Exception {
            Random random = new Random();
            long emitIntervalNanos = 1_000_000_000L / eventsPerSecond;

            int subtaskIndex = getRuntimeContext().getIndexOfThisSubtask();
            String keyPrefix = "key-" + subtaskIndex + "-";

            long lastEmitTime = System.nanoTime();

            while (running) {
                long now = System.nanoTime();
                if (now - lastEmitTime >= emitIntervalNanos) {
                    String key = keyPrefix + (random.nextInt(numKeys));
                    LoadEvent event = new LoadEvent(
                            key,
                            System.currentTimeMillis(),
                            random.nextDouble()
                    );
                    synchronized (ctx.getCheckpointLock()) {
                        ctx.collect(event);
                    }
                    lastEmitTime = now;
                } else {
                    // Small sleep to avoid busy spin
                    Thread.sleep(0, 200_000); // 0.2 ms
                }
            }
        }

        @Override
        public void cancel() {
            running = false;
        }
    }

    /**
     * Map function that simulates CPU-heavy work per event.
     */
    public static class CpuHeavyMap extends RichMapFunction<LoadEvent, LoadEvent> {

        private final int iterations;

        public CpuHeavyMap(int iterations) {
            this.iterations = iterations;
        }

        @Override
        public LoadEvent map(LoadEvent value) throws Exception {
            double x = value.payload;
            for (int i = 0; i < iterations; i++) {
                x = Math.sin(x) * Math.cos(x) + Math.log1p(Math.abs(x) + 1.0);
            }
            value.payload = x;
            return value;
        }
    }

    /**
     * Window function that counts events per key.
     * Uses ValueState to keep track of a running count (extra state load).
     */
    public static class CountingWindowFunction
            extends ProcessWindowFunction<LoadEvent, Tuple2<String, Long>, String, TimeWindow> {

        private transient ValueState<Long> totalCountState;

        @Override
        public void open(Configuration parameters) {
            ValueStateDescriptor<Long> desc =
                    new ValueStateDescriptor<>("totalCount", Long.class);
            totalCountState = getRuntimeContext().getState(desc);
        }

        @Override
        public void process(
                String key,
                Context context,
                Iterable<LoadEvent> elements,
                Collector<Tuple2<String, Long>> out) throws Exception {

            long windowCount = 0L;
            for (LoadEvent ignored : elements) {
                windowCount++;
            }

            Long total = totalCountState.value();
            if (total == null) {
                total = 0L;
            }
            total += windowCount;
            totalCountState.update(total);

            out.collect(Tuple2.of(key, windowCount));
        }
    }
}
