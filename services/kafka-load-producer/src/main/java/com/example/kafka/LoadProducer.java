package com.example.kafka;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.StringSerializer;

import java.util.Properties;
import java.util.Random;

/**
 * Standalone Kafka producer that generates JSON load events at a configurable rate.
 * Designed to drive the Flink autoscaling demo via Kafka consumer lag.
 */
public class LoadProducer {

    public static void main(String[] args) throws Exception {
        String bootstrapServers = getStringArg(args, "--bootstrap-servers",
                "autoscaling-load-kafka-bootstrap.kafka.svc.cluster.local:9092");
        String topic = getStringArg(args, "--topic", "load-events");
        int recordsPerSecond = getIntArg(args, "--records-per-second", 1000);
        int numKeys = getIntArg(args, "--keys", 128);

        System.out.printf("Starting LoadProducer: servers=%s, topic=%s, rps=%d, keys=%d%n",
                bootstrapServers, topic, recordsPerSecond, numKeys);

        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.ACKS_CONFIG, "1");
        props.put(ProducerConfig.LINGER_MS_CONFIG, "5");
        props.put(ProducerConfig.BATCH_SIZE_CONFIG, "16384");

        ObjectMapper mapper = new ObjectMapper();
        Random random = new Random();

        long intervalNanos = 1_000_000_000L / recordsPerSecond;
        long count = 0;

        try (KafkaProducer<String, String> producer = new KafkaProducer<>(props)) {
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                System.out.println("Shutting down LoadProducer...");
                producer.flush();
            }));

            long nextSendTime = System.nanoTime();

            while (true) {
                String key = "key-" + (count % numKeys);

                ObjectNode node = mapper.createObjectNode();
                node.put("key", key);
                node.put("timestamp", System.currentTimeMillis());
                node.put("payload", random.nextDouble());

                String value = mapper.writeValueAsString(node);

                producer.send(new ProducerRecord<>(topic, key, value));
                count++;

                if (count % 10000 == 0) {
                    System.out.printf("Produced %d records%n", count);
                }

                // Rate limiting
                nextSendTime += intervalNanos;
                long sleepNanos = nextSendTime - System.nanoTime();
                if (sleepNanos > 0) {
                    Thread.sleep(sleepNanos / 1_000_000, (int) (sleepNanos % 1_000_000));
                } else if (sleepNanos < -1_000_000_000L) {
                    // If we're more than 1 second behind, reset to avoid burst catching up
                    nextSendTime = System.nanoTime();
                }
            }
        }
    }

    private static String getStringArg(String[] args, String name, String defaultValue) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals(name)) {
                return args[i + 1];
            }
        }
        return defaultValue;
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
        return defaultValue;
    }
}
