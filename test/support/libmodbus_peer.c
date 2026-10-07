/*
 * libmodbus TCP / RTU peer for AVModbus interoperability tests.
 *
 * The request sequence and memory pattern are adapted from yamodbus's
 * Apache-2.0 test/support/libmodbus_peer.c.
 *
 *     libmodbus_peer server tcp PORT
 *     libmodbus_peer client tcp PORT
 *     libmodbus_peer server rtu DEVICE
 *     libmodbus_peer client rtu DEVICE
 */

#include <errno.h>
#include <modbus.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int is_tcp(const char *transport) {
  return strcmp(transport, "tcp") == 0;
}

static modbus_t *context(const char *transport, const char *target) {
  modbus_t *ctx = is_tcp(transport)
                      ? modbus_new_tcp("127.0.0.1", atoi(target))
                      : modbus_new_rtu(target, 19200, 'N', 8, 1);

  if (ctx == NULL) {
    fprintf(stderr, "context: %s\n", modbus_strerror(errno));
    exit(1);
  }

  modbus_set_slave(ctx, 1);
  modbus_set_response_timeout(ctx, 2, 0);
  if (getenv("LIBMODBUS_DEBUG") != NULL) modbus_set_debug(ctx, 1);
  return ctx;
}

static void serve_connection(modbus_t *ctx, modbus_mapping_t *mapping) {
  uint8_t query[MODBUS_MAX_ADU_LENGTH];

  for (;;) {
    int length = modbus_receive(ctx, query);

    if (length > 0) {
      modbus_reply(ctx, query, length, mapping);
    } else {
      fprintf(stderr, "receive: %s\n", modbus_strerror(errno));
      return;
    }
  }
}

static int serial_server(modbus_t *ctx, modbus_mapping_t *mapping) {
  if (modbus_connect(ctx) == -1) {
    fprintf(stderr, "connect: %s\n", modbus_strerror(errno));
    return 1;
  }

  printf("ready\n");
  fflush(stdout);
  serve_connection(ctx, mapping);
  modbus_close(ctx);
  return 0;
}

static int tcp_server(modbus_t *ctx, modbus_mapping_t *mapping) {
  int listener = modbus_tcp_listen(ctx, 1);

  if (listener == -1) {
    fprintf(stderr, "listen: %s\n", modbus_strerror(errno));
    return 1;
  }

  printf("ready\n");
  fflush(stdout);

  for (;;) {
    if (modbus_tcp_accept(ctx, &listener) == -1) return 1;
    serve_connection(ctx, mapping);
    modbus_close(ctx);
  }
}

static int server(const char *transport, const char *target) {
  modbus_t *ctx = context(transport, target);
  modbus_mapping_t *mapping = modbus_mapping_new(100, 100, 100, 100);

  if (mapping == NULL) {
    fprintf(stderr, "mapping: %s\n", modbus_strerror(errno));
    return 1;
  }

  for (int i = 0; i < 100; i++) {
    mapping->tab_registers[i] = 1000 + i;
    mapping->tab_input_registers[i] = 2000 + i;
    mapping->tab_bits[i] = i % 3 == 0;
    mapping->tab_input_bits[i] = i % 2 == 0;
  }

  int result = is_tcp(transport) ? tcp_server(ctx, mapping) : serial_server(ctx, mapping);
  modbus_mapping_free(mapping);
  modbus_free(ctx);
  return result;
}

static void words(const char *name, int count, const uint16_t *values) {
  if (count < 0) {
    printf("%s error %s\n", name, modbus_strerror(errno));
    return;
  }

  printf("%s ok", name);
  for (int i = 0; i < count; i++) printf(" %u", values[i]);
  printf("\n");
}

static void bits(const char *name, int count, const uint8_t *values) {
  if (count < 0) {
    printf("%s error %s\n", name, modbus_strerror(errno));
    return;
  }

  printf("%s ok", name);
  for (int i = 0; i < count; i++) printf(" %u", values[i]);
  printf("\n");
}

static void done(const char *name, int result) {
  if (result < 0) {
    printf("%s error %s\n", name, modbus_strerror(errno));
  } else {
    printf("%s ok\n", name);
  }
}

static int client(const char *transport, const char *target) {
  modbus_t *ctx = context(transport, target);
  uint16_t registers[16];
  uint8_t coils[16];
  uint16_t written[3] = {1, 2, 3};
  uint8_t pattern[3] = {1, 0, 1};
  uint16_t pair[2] = {7, 8};

  if (modbus_connect(ctx) == -1) {
    fprintf(stderr, "connect: %s\n", modbus_strerror(errno));
    return 1;
  }

  done("write_registers", modbus_write_registers(ctx, 10, 3, written));
  words("read_registers", modbus_read_registers(ctx, 10, 3, registers), registers);
  done("write_register", modbus_write_register(ctx, 20, 0x12));
  done("mask_write_register", modbus_mask_write_register(ctx, 20, 0xF2, 0x25));
  words("read_registers", modbus_read_registers(ctx, 20, 1, registers), registers);
  done("write_bits", modbus_write_bits(ctx, 5, 3, pattern));
  bits("read_bits", modbus_read_bits(ctx, 5, 3, coils), coils);
  done("write_bit", modbus_write_bit(ctx, 9, 1));
  bits("read_bits", modbus_read_bits(ctx, 9, 1, coils), coils);
  words("write_and_read_registers",
        modbus_write_and_read_registers(ctx, 30, 2, pair, 30, 2, registers), registers);
  words("read_input_registers", modbus_read_input_registers(ctx, 0, 2, registers), registers);
  bits("read_input_bits", modbus_read_input_bits(ctx, 0, 2, coils), coils);
  words("read_registers", modbus_read_registers(ctx, 999, 2, registers), registers);

  modbus_close(ctx);
  modbus_free(ctx);
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 4 || (strcmp(argv[2], "tcp") != 0 && strcmp(argv[2], "rtu") != 0)) {
    fprintf(stderr, "usage: libmodbus_peer server|client tcp PORT|rtu DEVICE\n");
    return 2;
  }

  setvbuf(stdout, NULL, _IOLBF, 0);
  return strcmp(argv[1], "server") == 0 ? server(argv[2], argv[3])
                                         : client(argv[2], argv[3]);
}
