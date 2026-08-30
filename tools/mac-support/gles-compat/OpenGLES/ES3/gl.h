/* Mac Catalyst compat: Apple spells this header <OpenGLES/ES3/gl.h> and
 * only the iOS SDK carries it. The macabi core builds compile against
 * ANGLE's GLES headers instead; this shim keeps upstream includes
 * untouched. See tools/build-n64.sh's mac case. */
#include <GLES3/gl3.h>
