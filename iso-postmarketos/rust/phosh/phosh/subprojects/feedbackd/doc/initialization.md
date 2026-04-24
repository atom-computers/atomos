Title: Initialization
Slug: initialization

# Initialization

Before using libfeedback, it must be initialized. To use the library
call [func@Lfb.init]() with the id of your application (usually
the desktop file name without the .desktop extension). For that you
include the `libfeedback.h` header. Since the API is considered
unstable at this point in time you need to acknowledge this by
defining `LIBFEEDBACK_USE_UNSTABLE_API`:

```c
  #define LIBFEEDBACK_USE_UNSTABLE_API
  #include <libfeedback.h>

  int main(void)
  {
     g_autoptr (GError) *err = NULL;
     if (lfb_init ("com.example.appid", &err)) {
       g_error ("%s", err->message);
     }
     ...
     lfb_uninit ();
     return 0;
  }
```

You can also acknowledge this with the definition option of your C
compiler, like `-DFEEDBACK_USE_UNSTABLE_API`.

After initializing the library you can trigger feedback using
[class@Lfb.Event] objects.  When your application finishes call
[func@Lfb.uninit]() to free any resources:
