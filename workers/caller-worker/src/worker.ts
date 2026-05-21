import { Logger, registerWorker } from 'iii-sdk';

const iii = registerWorker(process.env.III_URL ?? 'ws://localhost:49134');
const logger = new Logger();

iii.registerFunction(
  'inference::get_response',
  async (payload) => {
    const result = await iii.trigger({
      function_id: 'inference::run_inference',
      payload,
    });

    return result;
  },
);

iii.registerFunction(
  'http::run_inference_over_http',
  async (payload) => {
    const result = await iii.trigger({
      function_id: 'inference::get_response',
      payload: payload.body,
    });

    return {
      status_code: 200,
      headers: { 'Content-Type': 'application/json' },
      body: result,
    };
  },
);

iii.registerTrigger({
  type: 'http',
  function_id: 'http::run_inference_over_http',
  config: {
    api_path: '/v1/chat/completions',
    http_method: 'POST',
  },
});

logger.info('Caller worker started - listening for calls');