#include <assert.h>

#include "ejs-ops.h"
#include "ejs-value.h"
#include "ejs-date.h"

static EJSValue* _ejs_date_specop_get (EJSValue* obj, void* propertyName, EJSBool isCStr);
static EJSValue* _ejs_date_specop_get_own_property (EJSValue* obj, EJSValue* propertyName);
static EJSValue* _ejs_date_specop_get_property (EJSValue* obj, EJSValue* propertyName);
static void      _ejs_date_specop_put (EJSValue *obj, EJSValue* propertyName, EJSValue* val, EJSBool flag);
static EJSBool   _ejs_date_specop_can_put (EJSValue *obj, EJSValue* propertyName);
static EJSBool   _ejs_date_specop_has_property (EJSValue *obj, EJSValue* propertyName);
static EJSBool   _ejs_date_specop_delete (EJSValue *obj, EJSValue* propertyName, EJSBool flag);
static EJSValue* _ejs_date_specop_default_value (EJSValue *obj, const char *hint);
static void      _ejs_date_specop_define_own_property (EJSValue *obj, EJSValue* propertyName, EJSValue* propertyDescriptor, EJSBool flag);

EJSSpecOps _ejs_date_specops = {
  "Date",
  _ejs_date_specop_get,
  _ejs_date_specop_get_own_property,
  _ejs_date_specop_get_property,
  _ejs_date_specop_put,
  _ejs_date_specop_can_put,
  _ejs_date_specop_has_property,
  _ejs_date_specop_delete,
  _ejs_date_specop_default_value,
  _ejs_date_specop_define_own_property
};

EJSObject* _ejs_date_alloc_instance()
{
  return (EJSObject*)_ejs_gc_new (EJSDate);
}

EJSValue*
_ejs_date_new_unix (int timestamp)
{
  EJSDate* rv = _ejs_gc_new (EJSDate);

  _ejs_init_object ((EJSObject*)rv, _ejs_date_get_prototype(), NULL/*XXX*/);

  time_t t = (time_t)timestamp;

  if (!localtime_r(&t, &rv->tm))
    NOT_IMPLEMENTED();

  return (EJSValue*)rv;
}

EJSValue* _ejs_Date;
static EJSValue*
_ejs_Date_impl (EJSValue* env, EJSValue* _this, int argc, EJSValue **args)
{
  if (EJSVAL_IS_UNDEFINED(_this)) {
    // called as a function
    if (argc == 0) {
      return _ejs_date_new_unix(time(NULL));
    }
    else {
      NOT_IMPLEMENTED();
    }
  }
  else {
    printf ("called Date() as a constructor!\n");

    EJSDate* date = (EJSDate*) _this;

    // new Date (year, month [, date [, hours [, minutes [, seconds [, ms ] ] ] ] ] )

    if (argc <= 1) {
      time_t t = (time_t)time(NULL);

      if (!gmtime_r(&t, &date->tm))
	NOT_IMPLEMENTED();
    }
    else {
      // there are all sorts of validation steps here that are missing from ejs
      date->tm.tm_year = (int)(ToDouble(args[0]) - 1900);
      date->tm.tm_mon = (int)(ToDouble(args[1]));
      if (argc > 2) date->tm.tm_mday = (int)(ToDouble(args[2]));
      if (argc > 3) date->tm.tm_hour = (int)(ToDouble(args[3]));
      if (argc > 4) date->tm.tm_min = (int)(ToDouble(args[4]));
      if (argc > 5) date->tm.tm_sec = (int)(ToDouble(args[5]));
      // ms?
    }
      
    return _this;
  }
}

static EJSValue* _ejs_Date_proto;
EJSValue*
_ejs_date_get_prototype()
{
  return _ejs_Date_proto;
}

static EJSValue*
_ejs_Date_prototype_toString (EJSValue* env, EJSValue* _this, int argc, EJSValue **args)
{
  EJSDate *date = (EJSDate*)_this;

  // returns strings of the format 'Tue Aug 28 2012 16:45:58 GMT-0700 (PDT)'

  char date_buf[256];
  if (date->tm.tm_gmtoff == 0)
    strftime (date_buf, sizeof(date_buf), "%a %b %d %Y %T GMT", &date->tm);
  else
    strftime (date_buf, sizeof(date_buf), "%a %b %d %Y %T GMT%z (%Z)", &date->tm);

  return _ejs_string_new_utf8 (date_buf);
}

static EJSValue*
_ejs_Date_prototype_getTimezoneOffset (EJSValue* env, EJSValue* _this, int argc, EJSValue **args)
{
  EJSDate *date = (EJSDate*)_this;

  return _ejs_number_new (date->tm.tm_gmtoff);
}

void
_ejs_date_init(EJSValue *global)
{
  START_SHADOW_STACK_FRAME;

  _ejs_gc_add_named_root (_ejs_Date_proto);
  _ejs_Date_proto = _ejs_object_new(NULL);

  ADD_STACK_ROOT(EJSValue*, tmpobj, _ejs_function_new_utf8 (NULL, "Date", (EJSClosureFunc)_ejs_Date_impl));
  _ejs_Date = tmpobj;

  _ejs_object_setprop_utf8 (_ejs_Date,       "prototype",  _ejs_Date_proto);

#define OBJ_METHOD(x) do { ADD_STACK_ROOT(EJSValue*, funcname, _ejs_string_new_utf8(#x)); ADD_STACK_ROOT(EJSValue*, tmpfunc, _ejs_function_new (NULL, funcname, (EJSClosureFunc)_ejs_Date_##x)); _ejs_object_setprop (_ejs_Date, funcname, tmpfunc); } while (0)
#define PROTO_METHOD(x) do { ADD_STACK_ROOT(EJSValue*, funcname, _ejs_string_new_utf8(#x)); ADD_STACK_ROOT(EJSValue*, tmpfunc, _ejs_function_new (NULL, funcname, (EJSClosureFunc)_ejs_Date_prototype_##x)); _ejs_object_setprop (_ejs_Date_proto, funcname, tmpfunc); } while (0)

  PROTO_METHOD(toString);
  PROTO_METHOD(getTimezoneOffset);

#undef OBJ_METHOD
#undef PROTO_METHOD

  _ejs_object_setprop_utf8 (global, "Date", _ejs_Date);

  END_SHADOW_STACK_FRAME;
}

static EJSValue*
_ejs_date_specop_get (EJSValue* obj, void* propertyName, EJSBool isCStr)
{
  return _ejs_object_specops.get (obj, propertyName, isCStr);
}

static EJSValue*
_ejs_date_specop_get_own_property (EJSValue* obj, EJSValue* propertyName)
{
  return _ejs_object_specops.get_own_property (obj, propertyName);
}

static EJSValue*
_ejs_date_specop_get_property (EJSValue* obj, EJSValue* propertyName)
{
  return _ejs_object_specops.get_property (obj, propertyName);
}

static void
_ejs_date_specop_put (EJSValue *obj, EJSValue* propertyName, EJSValue* val, EJSBool flag)
{
  _ejs_object_specops.put (obj, propertyName, val, flag);
}

static EJSBool
_ejs_date_specop_can_put (EJSValue *obj, EJSValue* propertyName)
{
  return _ejs_object_specops.can_put (obj, propertyName);
}

static EJSBool
_ejs_date_specop_has_property (EJSValue *obj, EJSValue* propertyName)
{
  return _ejs_object_specops.has_property (obj, propertyName);
}

static EJSBool
_ejs_date_specop_delete (EJSValue *obj, EJSValue* propertyName, EJSBool flag)
{
  return _ejs_object_specops._delete (obj, propertyName, flag);
}

static EJSValue*
_ejs_date_specop_default_value (EJSValue *obj, const char *hint)
{
  return _ejs_object_specops.default_value (obj, hint);
}

static void
_ejs_date_specop_define_own_property (EJSValue *obj, EJSValue* propertyName, EJSValue* propertyDescriptor, EJSBool flag)
{
  _ejs_object_specops.define_own_property (obj, propertyName, propertyDescriptor, flag);
}
