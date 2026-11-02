# Golazo Infinito

Arcade de tiros libres infinitos para móvil, en pixel art. Física real de balón (rosca por efecto Magnus, resistencia del aire, bote en el césped, postes y red), barrera que salta, defensas que salen a tapar, una escalera de 20 porteros que van de peor a mejor (de Karius hasta Benji Price) y un ranking público.

Todo el juego es un único `index.html` sin dependencias ni paso de compilación, así que se publica tal cual en GitHub Pages.

## Cómo se juega

- **Deslizar:** desliza el dedo desde el balón hacia la portería. Más rápido es más potencia, más largo es más alto, y si curvas el gesto el balón toma rosca.
- **Tirachinas:** arrastra hacia atrás para apuntar y dar potencia, suelta y toca el balón donde quieras golpearlo (de lado da rosca, abajo lo eleva, arriba sale raso y cae).

Tienes 3 balones. Cada gol seguido sube el multiplicador hasta x10.

## Modo torneo

Seis partidos contra selecciones, cada una con su portero y una regla propia (viento fuerte, barrera de cinco, defensa tumbado, un defensa que sale a tapar…): tres de grupo (pasas con 4 puntos) y cuartos, semis y una final contra Benji Price, que se tira al lado de tu último tiro. El cuadro se sortea al empezar a partir de una semilla, así que la misma semilla da siempre los mismos rivales y los mismos tiros. En cada partido tienes 5 tiros para superar el marcador del rival; en grupos el empate da 1 punto y en eliminatorias se va a penaltis (cinco por bando y después muerte súbita). Entre partidos eliges una de tres cartas: **entrenamiento** (una mejora gratis), **tienda** (mejoras a cambio de monedas) o un **evento** de riesgo y recompensa. Hay 16 mejoras en cuatro familias (balón, tirador, multiplicadores y sabotajes al rival), de comunes a legendarias, y las monedas se ganan marcando y ganando partidos. Puntúan los goles como en el modo infinito, más un premio por cada partido ganado, 500 por cada tiro que te sobre, 10.000 por ser campeón y 10 por cada moneda sin gastar. El récord del torneo se guarda aparte en el dispositivo.

## App instalable

Golazo es una PWA: se instala en el móvil y se abre a pantalla completa, sin barra del navegador, con su icono y pantalla de arranque.

- **Android (Chrome):** botón **INSTALAR APP** en la pantalla de inicio, o menú ⋮ → *Instalar aplicación*.
- **iPhone (Safari):** el botón **INSTALAR APP** explica los pasos: Compartir → *Añadir a pantalla de inicio*.

Una vez abierta funciona sin conexión (el ranking necesita red, pero las partidas pendientes se envían después). Mantiene la pantalla encendida mientras juegas, silencia el sonido al salir de la app y tiene un atajo a **Ranking** al mantener pulsado el icono en Android.

`sw.js` pide la página y `config.js` primero a la red, así que cada cambio que subas llega solo a los jugadores sin tocar versiones. Si cambias iconos o imágenes, sube el número de `SHELL_CACHE` en `sw.js` para que se refresquen.

## Ranking público

Al entrar, el juego pide un nombre de jugador. El nombre es único (sin distinguir mayúsculas) y queda guardado en el dispositivo junto a un token secreto, así que nadie más puede jugar con tu nombre. También se puede jugar como invitado, pero esas puntuaciones no entran en el ranking. Si un invitado hace una buena partida, puede crear su nombre al terminar y guardarla.

El ranking guarda la mejor partida de cada jugador y tiene dos vistas: **Semana** (últimos 7 días) y **Siempre**. Si una partida no se puede enviar por falta de conexión, se guarda y se envía en la siguiente.

Los datos viven en [Supabase](https://supabase.com) (plan gratuito). GitHub Pages solo sirve archivos estáticos, así que el navegador habla directamente con Supabase.

### Puesta en marcha

1. Crea un proyecto en Supabase.
2. Abre **SQL Editor**, pega el contenido de [`supabase/schema.sql`](supabase/schema.sql) y pulsa **Run**. Crea las tablas y las funciones; se puede volver a ejecutar sin perder datos.
3. En **Project Settings → API** copia la **Project URL** y la clave **publishable** (o la `anon` si tu proyecto usa las claves antiguas).
4. Pega ambos valores en [`config.js`](config.js) y haz commit.

La clave publishable es pública por diseño. Las tablas tienen Row Level Security activado y sin políticas, así que desde el navegador no se pueden leer ni modificar directamente: solo se puede llamar a estas funciones, que validan cada petición.

| Función | Qué hace |
|---|---|
| `name_available(p_name)` | Dice si un nombre está libre |
| `register_player(p_name)` | Crea el jugador y devuelve su token (en la base solo se guarda el hash) |
| `submit_score(p_player, p_token, p_score, p_goals, p_streak)` | Guarda una partida si el token es correcto y la puntuación es posible |
| `get_leaderboard(p_period, p_limit)` | Mejor partida de cada jugador, `week` o `all` |
| `get_player_standing(p_player, p_period)` | Posición de un jugador aunque no salga en el top |
| `submit_rogue(...)` | Guarda un torneo terminado |
| `daily_status(p_player)` / `start_daily(p_player, p_token)` | Estado del reto de hoy / gastar el único intento del día |
| `save_daily(...)` | Guarda el progreso del reto mientras se juega y lo cierra al acabar |
| `get_rogue_leaderboard(p_mode, p_limit)` / `get_rogue_standing(p_player, p_mode)` | Ranking del torneo (`week`, `all`) o del reto de hoy (`daily`) |

Como el juego corre entero en el navegador, alguien con conocimientos podría enviar una puntuación inventada. El servidor rechaza las imposibles (más de ~28.000 puntos por gol, rachas mayores que los goles) y limita a una partida cada 5 segundos por jugador. Si alguien hace trampas, se puede borrar desde Supabase (**Table Editor → scores**).

Sin `config.js` rellenado el juego funciona igual, sin nombres ni ranking.

### Ranking del torneo y reto diario

El torneo tiene su propio ranking (semana y siempre) y un **reto diario**: el mismo torneo para todos cada día (la semilla sale de la fecha, en hora de Madrid), un solo intento por jugador y con nombre obligatorio. El intento cuenta desde que empieza: el progreso se guarda después de cada partido y al salir de la app, así que cerrarla a mitad deja la puntuación que llevabas.

Estas tablas y funciones están al final de [`supabase/schema.sql`](supabase/schema.sql). Si ya tenías el ranking montado, vuelve a pegar el archivo entero en el SQL Editor y pulsa **Run**: no toca los datos existentes. Mientras no lo ejecutes, el juego funciona igual: el botón del reto no aparece y los torneos se guardan en el dispositivo para enviarse cuando el ranking esté listo.

## Publicar en GitHub Pages

**Settings → Pages → Build and deployment**: *Deploy from a branch*, rama `main`, carpeta `/ (root)`. La web queda en `https://danuve3.github.io/golazo/`.

## Desarrollo local

Sirve la carpeta con cualquier servidor estático, por ejemplo `npx serve .` o `python3 -m http.server`, y abre `http://localhost:3000` (o el puerto que use). En `localhost` se activa `window.__golazo` con utilidades de depuración.
