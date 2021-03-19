package reconciler

import (
	"context"
	"time"

	pvpoolv1alpha1 "github.com/puppetlabs/pvpool/pkg/apis/pvpool.puppet.com/v1alpha1"
	pvpoolv1alpha1obj "github.com/puppetlabs/pvpool/pkg/apis/pvpool.puppet.com/v1alpha1/obj"
	"github.com/puppetlabs/pvpool/pkg/controller/app"
	"github.com/puppetlabs/pvpool/pkg/opt"
	"golang.org/x/time/rate"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/util/workqueue"
	"k8s.io/klog/v2"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// +kubebuilder:rbac:groups=pvpool.puppet.com,resources=checkouts,verbs=get;list;watch
// +kubebuilder:rbac:groups=pvpool.puppet.com,resources=checkouts/status,verbs=update
// +kubebuilder:rbac:groups=core,resources=events,verbs=create;patch
// +kubebuilder:rbac:groups=core,resources=persistentvolumes,verbs=get;list;watch;update
// +kubebuilder:rbac:groups=core,resources=persistentvolumeclaims,verbs=get;list;watch;create;update;delete

type CheckoutReconciler struct {
	cl client.Client
}

var _ reconcile.Reconciler = &CheckoutReconciler{}

func (pr *CheckoutReconciler) Reconcile(ctx context.Context, req reconcile.Request) (r reconcile.Result, err error) {
	klog.InfoS("checkout reconciler: starting reconcile for checkout", "checkout", req.NamespacedName)
	defer klog.InfoS("checkout reconciler: ending reconcile for checkout", "checkout", req.NamespacedName)
	defer func() {
		if err != nil {
			klog.ErrorS(err, "checkout reconciler: failed to reconcile checkout", "checkout", req.NamespacedName)
		}
	}()

	checkout := pvpoolv1alpha1obj.NewCheckout(req.NamespacedName)
	if ok, err := checkout.Load(ctx, pr.cl); err != nil || !ok {
		return reconcile.Result{}, err
	}

	cs := app.NewCheckoutState(checkout)
	defer func() {
		checkout = app.ConfigureCheckout(cs)
		if serr := checkout.PersistStatus(ctx, pr.cl); serr != nil {
			if err == nil {
				err = serr
			} else {
				klog.ErrorS(serr, "checkout reconciler: failed to update checkout status", "pool", req.NamespacedName)
			}
		}
	}()

	if ok, err := cs.Load(ctx, pr.cl); err != nil || !ok {
		return reconcile.Result{Requeue: true}, err
	}

	cs, err = app.ConfigureCheckoutState(cs)
	if err != nil {
		return reconcile.Result{}, err
	}

	err = cs.Persist(ctx, pr.cl)
	return
}

func NewCheckoutReconciler(cl client.Client) *CheckoutReconciler {
	return &CheckoutReconciler{
		cl: cl,
	}
}

func AddCheckoutReconcilerToManager(mgr manager.Manager, cfg *opt.Config) error {
	rl := workqueue.NewMaxOfRateLimiter(
		workqueue.NewItemExponentialFailureRateLimiter(5*time.Millisecond, cfg.ControllerMaxReconcileBackoffDuration),
		&workqueue.BucketRateLimiter{Limiter: rate.NewLimiter(rate.Limit(10), 100)},
	)

	r := NewCheckoutReconciler(mgr.GetClient())

	return builder.ControllerManagedBy(mgr).
		For(&pvpoolv1alpha1.Checkout{}).
		Owns(&corev1.PersistentVolumeClaim{}).
		WithOptions(controller.Options{RateLimiter: rl}).
		Complete(r)
}
