# AXE — modelo de fluidez

AXE separa el trabajo visual del trabajo de medicion. La UI vive en WebView2 y la telemetria continua usa un productor de fondo y un `DispatcherTimer` que solo consume un buffer.

Las operaciones largas (`fps.capture`, benchmark, red, medicion) pueden tardar varios segundos por diseño. El cliente RPC usa timeouts por operacion para que la UI no marque como fallida una medicion que sigue ejecutandose correctamente.

Esto no convierte automaticamente una operacion sincronica del motor en una tarea de fondo: el punto pendiente para una futura iteracion es desacoplar completamente las operaciones largas del hilo de despacho del bridge.

## Regla de mantenimiento

No reducir tiempos de medicion solo para que la interfaz parezca rapida. Una medicion mas corta que pierde estabilidad o representatividad es una regresion de calidad, no una mejora de rendimiento.
