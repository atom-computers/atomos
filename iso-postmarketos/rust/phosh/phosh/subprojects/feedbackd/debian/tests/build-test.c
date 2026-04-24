#define LIBFEEDBACK_USE_UNSTABLE_API
#include <libfeedback.h>

int
main (int    argc,
      char **argv)
{
  lfb_init("org.sigxcpu.autopkgtest1", NULL);
}
