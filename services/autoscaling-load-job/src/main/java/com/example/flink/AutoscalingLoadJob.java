package com.example.flink;

import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.functions.MapFunction;
import org.apache.flink.api.common.functions.RichMapFunction;
import org.apache.flink.api.common.serialization.SimpleStringSchema;
import org.apache.flink.api.common.state.ValueState;
import org.apache.flink.api.common.state.ValueStateDescriptor;
import org.apache.flink.api.java.tuple.Tuple2;
import org.apache.flink.configuration.Configuration;
import org.apache.flink.connector.kafka.source.KafkaSource;
import org.apache.flink.connector.kafka.source.enumerator.initializer.OffsetsInitializer;
import org.apache.flink.streaming.api.CheckpointingMode;
import org.apache.flink.streaming.api.datastream.SingleOutputStreamOperator;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.windowing.ProcessWindowFunction;
import org.apache.flink.streaming.api.windowing.assigners.TumblingProcessingTimeWindows;
import org.apache.flink.streaming.api.windowing.time.Time;
import org.apache.flink.streaming.api.windowing.windows.TimeWindow;
import org.apache.flink.util.Collector;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

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
        String sourceType = getStringArg(args, "--source-type", "synthetic");
        int cpuWorkIterations = getIntArg(args, "--cpu-iterations", 10_000);
        int numKeys = getIntArg(args, "--keys", 128);
        int windowSeconds = getIntArg(args, "--window-seconds", 30);

        // Kafka-specific params
        String kafkaBootstrapServers = getStringArg(args, "--kafka-bootstrap-servers",
                "autoscaling-load-kafka-bootstrap.kafka.svc.cluster.local:9092");
        String kafkaTopic = getStringArg(args, "--kafka-topic", "load-events");
        String kafkaGroupId = getStringArg(args, "--kafka-group-id", "autoscaling-load-consumer");

        System.out.printf(
            "Starting AutoscalingLoadJob with source=%s, cpu-iterations=%d, keys=%d, window=%ds%n",
            sourceType, cpuWorkIterations, numKeys, windowSeconds
        );

        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

        // Optional: enable checkpoints so state grows and is snapshotted
        env.enableCheckpointing(30_000, CheckpointingMode.EXACTLY_ONCE);
        env.getCheckpointConfig().setMinPauseBetweenCheckpoints(5_000);

        SingleOutputStreamOperator<LoadEvent> source;

        if ("kafka".equalsIgnoreCase(sourceType)) {
            System.out.printf("Using KafkaSource: servers=%s, topic=%s, group=%s%n",
                    kafkaBootstrapServers, kafkaTopic, kafkaGroupId);

            KafkaSource<String> kafkaSource = KafkaSource.<String>builder()
                    .setBootstrapServers(kafkaBootstrapServers)
                    .setTopics(kafkaTopic)
                    .setGroupId(kafkaGroupId)
                    .setStartingOffsets(OffsetsInitializer.latest())
                    .setValueOnlyDeserializer(new SimpleStringSchema())
                    .build();

            source = env.fromSource(kafkaSource, WatermarkStrategy.noWatermarks(), "kafka-source")
                    .uid("kafka-load-source")
                    .map(new JsonToLoadEventMap())
                    .name("json-to-load-event")
                    .map(new CpuHeavyMap(cpuWorkIterations))
                    .name("cpu-heavy-map")
                    .uid("cpu-heavy-map");
        } else {
            // 1) Synthetic load source using new Source API (FLIP-27)
            // This properly exposes busyTimeMsPerSecond metric for autoscaling
            // Using NumberSequenceSource for truly unbounded generation
            org.apache.flink.api.connector.source.lib.NumberSequenceSource numberSource =
                    new org.apache.flink.api.connector.source.lib.NumberSequenceSource(0, Long.MAX_VALUE);

            final int keyCount = numKeys;
            source = env.fromSource(numberSource, WatermarkStrategy.noWatermarks(), "number-source")
                    .uid("synthetic-load-source")
                    .map(new RichMapFunction<Long, LoadEvent>() {
                        private transient Random random;

                        @Override
                        public LoadEvent map(Long index) throws Exception {
                            if (random == null) {
                                random = new Random();
                            }
                            String key = "key-" + (index % keyCount);
                            return new LoadEvent(key, System.currentTimeMillis(), random.nextDouble());
                        }
                    })
                    .name("load-event-generator")
                    .map(new CpuHeavyMap(cpuWorkIterations))
                    .name("cpu-heavy-map")
                    .uid("cpu-heavy-map");
        }

        // 3) Keyed tumbling window with simple stateful aggregation
        source.keyBy(e -> e.key)
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

    private static String getStringArg(String[] args, String name, String defaultValue) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals(name)) {
                return args[i + 1];
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
     * Deserializes JSON strings into LoadEvent POJOs.
     */
    public static class JsonToLoadEventMap implements MapFunction<String, LoadEvent> {
        private transient ObjectMapper mapper;

        @Override
        public LoadEvent map(String json) throws Exception {
            if (mapper == null) {
                mapper = new ObjectMapper();
            }
            JsonNode node = mapper.readTree(json);
            String key = node.has("key") ? node.get("key").asText() : "unknown";
            long timestamp = node.has("timestamp") ? node.get("timestamp").asLong() : System.currentTimeMillis();
            double payload = node.has("payload") ? node.get("payload").asDouble() : 0.0;
            return new LoadEvent(key, timestamp, payload);
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
