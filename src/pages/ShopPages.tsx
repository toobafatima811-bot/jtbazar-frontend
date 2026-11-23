import { ArrowLeft, ArrowRight, Search, SlidersHorizontal } from 'lucide-react'
import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { EmptyState, ErrorState, LoadingState } from '../components/common/States'
import { CategoryCard } from '../components/products/CategoryCard'
import { ProductGrid } from '../components/products/ProductGrid'
import { useCatalog } from '../contexts/CatalogContext'
import { usePageMeta } from '../hooks/usePageMeta'
import { useI18n } from '../i18n/LocaleContext'
import { useInfiniteProducts } from '../hooks/useInfiniteProducts'
import type { Category } from '../types/category'
import type { Product } from '../types/product'
import type { PriceSort } from '../components/products/FilterControls'

type Translator = (english: string) => string

function CatalogSearch({ t }: { t: Translator }) {
  const [value, setValue] = useState('')
  const navigate = useNavigate()
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const query = value.trim()
    navigate(query ? `/search?q=${encodeURIComponent(query)}` : '/search')
  }
  return <form className="search-field" role="search" onSubmit={submit}><Search size={17} aria-hidden="true" /><label className="sr-only" htmlFor="catalog-search">{t('Search items')}</label><input id="catalog-search" type="search" placeholder={t('Search products, categories…')} value={value} onChange={(event) => setValue(event.target.value)} /><button type="submit" className="search-submit">{t('Search')}</button></form>
}

function CatalogFilters({ selected, onToggle, onClear, sort, onSort, count, categories, t }: { selected: string[]; onToggle: (id: string) => void; onClear: () => void; sort: PriceSort; onSort: (sort: PriceSort) => void; count: number; categories: Category[]; t: Translator }) {
  const [expanded, setExpanded] = useState<string[]>([])
  const parents = categories.filter((item) => !item.parentId && item.isActive !== false && !item.isComingSoon)
  const childrenFor = (parentId: string) => categories.filter((item) => item.parentId === parentId && item.isActive !== false && !item.isComingSoon)
  const selectedNames = categories.filter((item) => selected.includes(item.id))
  return <section className="catalog-filter-panel" aria-label={t('Product filters')}>
    <div className="catalog-filter-toolbar">
      <div className="catalog-filter-toolbar__title"><SlidersHorizontal size={17}/><strong>{t('Filters')}</strong><span>{count} {t('products')}</span></div>
      <div className="catalog-filter-toolbar__actions">{selected.length > 0 && <button type="button" className="catalog-clear-filters" onClick={onClear}>{t('Clear all')}</button>}<label htmlFor="price-sort" className="sr-only">{t('Sort products by price')}</label><select id="price-sort" value={sort} onChange={(event) => onSort(event.target.value as PriceSort)}><option value="featured">{t('Featured')}</option><option value="price-low">{t('Price: low to high')}</option><option value="price-high">{t('Price: high to low')}</option></select></div>
    </div>
    {selectedNames.length > 0 && <div className="catalog-selected-filters" aria-label={t('Selected filters')}>{selectedNames.map((item) => <button type="button" key={item.id} onClick={() => onToggle(item.id)}>{t(item.name)} <span aria-hidden="true">×</span></button>)}</div>}
    <div className="catalog-filter-groups">{parents.map((parent) => {
      const children = childrenFor(parent.id)
      const checked = selected.includes(parent.id) || (children.length > 0 && children.every((child) => selected.includes(child.id)))
      const open = expanded.includes(parent.id)
      return <div className="catalog-filter-group" key={parent.id}>
        <div className="catalog-filter-parent">
          <label><input type="checkbox" checked={checked} onChange={() => onToggle(parent.id)}/><span>{t(parent.name)}</span><small>{children.length || 0}</small></label>
          {children.length > 0 && <button type="button" className="catalog-filter-expand" aria-label={open ? t('Collapse subcategories') : t('Expand subcategories')} aria-expanded={open} onClick={() => setExpanded((old) => open ? old.filter((id) => id !== parent.id) : [...old, parent.id])}>{open ? '−' : '+'}</button>}
        </div>
        {open && children.length > 0 && <div className="catalog-filter-children">{children.map((child) => <label key={child.id}><input type="checkbox" checked={selected.includes(child.id) || selected.includes(parent.id)} onChange={() => onToggle(child.id)}/><span>{t(child.name)}</span></label>)}</div>}
      </div>
    })}</div>
  </section>
}



function CatalogState({ status, error }: { status: 'loading' | 'ready' | 'error' | 'unconfigured'; error: string | null }) {
  if (status === 'loading') return <LoadingState label="Loading the live catalog…" />
  if (status === 'error') return <ErrorState message={error || 'The catalog could not be loaded.'} />
  if (status === 'unconfigured') return <ErrorState message="The store is not connected to its catalog service. Please check back later." />
  return null
}

function ProductLoadMore({ loading, hasMore, onLoad }: { loading: boolean; hasMore: boolean; onLoad: () => void }) {
  if (!hasMore && !loading) return null
  return <div className="catalog-load-more" aria-live="polite">
    <button type="button" className="button button--dark" onClick={onLoad} disabled={loading || !hasMore}>
      {loading ? 'Loading more products…' : 'Load More Products'}
    </button>
  </div>
}

export function ShopPage() {
  const { t } = useI18n()
  const { categories } = useCatalog()
  const [selectedCategories, setSelectedCategories] = useState<string[]>([])
  const [sort, setSort] = useState<PriceSort>('featured')
  const toggleCategory = (id: string) => setSelectedCategories((old) => {
    const item = categories.find((category) => category.id === id)
    if (!item) return old
    if (!item.parentId) {
      const children = categories.filter((category) => category.parentId === id).map((category) => category.id)
      const isFullySelected = old.includes(id) || (children.length > 0 && children.every((childId) => old.includes(childId)))
      return isFullySelected ? old.filter((value) => value !== id && !children.includes(value)) : [...old.filter((value) => !children.includes(value)), id]
    }
    if (old.includes(item.parentId)) {
      const siblings = categories.filter((category) => category.parentId === item.parentId).map((category) => category.id)
      return [...old.filter((value) => value !== item.parentId && value !== id), ...siblings.filter((value) => value !== id)]
    }
    return old.includes(id) ? old.filter((value) => value !== id) : [...old, id]
  })
  const categoryIds = useMemo(() => {
    const ids = new Set<string>()
    selectedCategories.forEach((id) => {
      ids.add(id)
      categories.filter((item) => item.parentId === id && item.isActive !== false && !item.isComingSoon).forEach((child) => ids.add(child.id))
    })
    return [...ids].sort()
  }, [selectedCategories, categories])
  const page = useInfiniteProducts({ categoryIds, sort })
  usePageMeta(t('Shop the collection'), t('Explore the currently published JTBazar catalog.'))
  return <div className="page-shell shop-catalog-page"><div className="page-heading page-heading--with-search shop-catalog-heading"><div><span className="eyebrow">{t('Shop JTBazar')}</span><h1>{t('Shop all products')}</h1><p>{t('Find everyday essentials, popular picks and new arrivals from trusted JTBazar sellers.')}</p></div><CatalogSearch t={t} /></div><CatalogFilters selected={selectedCategories} onToggle={toggleCategory} onClear={() => setSelectedCategories([])} sort={sort} onSort={setSort} count={page.count} categories={categories} t={t} />{page.loading ? <LoadingState label="Loading the live catalog…" /> : page.error && page.products.length === 0 ? <ErrorState message={page.error} /> : <><ProductGrid products={page.products} emptyTitle={t('No products are published yet')} emptyDescription={t('New listings will appear after sellers add products and they pass moderation.')} /><ProductLoadMore loading={page.loadingMore} hasMore={page.hasMore} onLoad={page.loadMore} />{page.error && <ErrorState message={page.error} />}</>}</div>
}

export function CategoriesPage() {
  const { t } = useI18n()
  const { categories, status, error } = useCatalog()
  usePageMeta(t('Browse categories'), t('Browse active product categories in the JTBazar store.'))
  return <div className="page-shell"><Link to="/shop" className="back-link"><ArrowLeft size={15} /> {t('Shop all')}</Link><div className="page-heading"><span className="eyebrow">{t('A place for every page')}</span><h1>{t('Browse the')} <em>{t('collections.')}</em></h1><p>{t('Choose an active category to explore published products.')}</p></div><CatalogState status={status} error={error} />{status === 'ready' && (categories.length ? <div className="category-grid category-grid--large">{categories.map((category) => <CategoryCard key={category.id} category={category} />)}</div> : <EmptyState title="No categories are published yet" description="Active categories will appear here after they are configured in the store." actionLabel="Browse the collection" actionHref="/shop" />)}</div>
}

export function CategoryPage() {
  const { t } = useI18n()
  const { slug = '' } = useParams()
  const navigate = useNavigate()
  const { categories } = useCatalog()
  const category = categories.find((item) => item.slug === slug && item.isActive !== false)
  const foodSubcategories = category?.isFoodCategory ? categories.filter((item) => item.parentId === category.id && item.isActive !== false) : []
  const [sort, setSort] = useState<PriceSort>('featured')
  const page = useInfiniteProducts({ categoryId: category?.id ?? null, sort: sort === 'featured' ? 'featured' : sort === 'price-low' ? 'price-low' : 'price-high', enabled: Boolean(category) })
  usePageMeta(category ? t(category.seoTitle || category.name) : t('Collection not found'), category ? t(category.seoDescription || `Explore published ${category.name} products on JTBazar in Pakistan.`) : t('This collection could not be found.'), { noIndex: !category })
  if (!category) return <div className="page-shell"><EmptyState title="That collection isn't here" description="Try another active category or browse the full catalog." actionLabel="Browse the collection" actionHref="/shop" /></div>
  return <div className="page-shell category-page">
    <nav className="category-breadcrumb" aria-label={t('Breadcrumb')}>
      <Link to="/shop">{t('Shop')}</Link><ArrowRight size={13} aria-hidden="true" />
      <Link to="/categories">{t('All collections')}</Link><ArrowRight size={13} aria-hidden="true" />
      <span aria-current="page">{t(category.name)}</span>
    </nav>
    <div className={`category-hero${category.isFoodCategory ? ' category-hero--food' : ''}${category.image ? ' has-image' : ' no-image'}`}>
      <div className="category-hero__copy">
        <span className="eyebrow">{t(category.eyebrow ?? 'Collection')}</span>
        <h1>{t(category.name)}</h1>
        <p>{t(category.description)}</p>
        <div className="category-hero__meta">
          <span className="category-hero__count"><strong>{page.count}</strong><span>{t('products in this collection')}</span></span>
          <a className="category-hero__cta" href="#category-product-results">{t('Shop products')} <ArrowRight size={15} aria-hidden="true" /></a>
        </div>
      </div>
      {category.image && <div className="category-hero__image-wrap"><img src={category.image} alt={t(category.name)} loading="eager" fetchPriority="high" /><span>{t('Explore collection')}</span></div>}
    </div>
    {foodSubcategories.length > 0 && <section className="food-subcategories"><div className="section-heading"><span className="eyebrow">{t('Explore Food')}</span><h2>{t('Food subcategories')}</h2></div><div className="category-grid">{foodSubcategories.map((item) => <CategoryCard key={item.id} category={item} />)}</div></section>}
    <div id="category-product-results" className="category-page__results">
      <CatalogFilters category={category.id} onCategory={(id) => navigate(id === 'all' ? '/shop' : `/categories/${categories.find((item) => item.id === id)?.slug ?? ''}`)} sort={sort} onSort={setSort} count={page.count} categories={category.isFoodCategory ? [] : categories.filter((item) => item.parentId === category.id)} t={t} />
      {page.loading ? <LoadingState label="Loading category products…" /> : page.error && page.products.length === 0 ? <ErrorState message={page.error} /> : <><ProductGrid products={page.products} emptyTitle={t('Nothing on this page yet')} emptyDescription={t('Try another category or clear your filters.')} /><ProductLoadMore loading={page.loadingMore} hasMore={page.hasMore} onLoad={page.loadMore} />{page.error && <ErrorState message={page.error} />}</>}
    </div>
  </div>
}

export function SearchPage() {
  const { t } = useI18n()
  const [params] = useSearchParams()
  const initial = params.get('q') ?? ''
  const [query, setQuery] = useState(initial)
  const [debounced, setDebounced] = useState(initial)
  const { categories } = useCatalog()
  useEffect(() => setQuery(initial), [initial])
  useEffect(() => { const timer = window.setTimeout(() => setDebounced(query.trim()), 300); return () => window.clearTimeout(timer) }, [query])
  const page = useInfiniteProducts({ search: debounced, enabled: Boolean(debounced) })
  usePageMeta(t('Search the catalog'), t('Search currently published JTBazar products and active categories.'))
  return <div className="page-shell"><Link to="/shop" className="back-link"><ArrowLeft size={15} /> {t('Shop all')}</Link><div className="search-page-heading"><span className="eyebrow">{t('Find a useful item')}</span><h1>{t('Search the')} <em>{t('collection.')}</em></h1><form className="search-page-form" onSubmit={(event) => event.preventDefault()}><Search size={19} /><label className="sr-only" htmlFor="search-results-query">{t('Search items')}</label><input id="search-results-query" type="search" autoFocus value={query} onChange={(event) => setQuery(event.target.value)} placeholder={t('Try a product or category name')} /></form><p>{debounced ? `${page.count} ${t(page.count === 1 ? 'product' : 'products')} ${t('for')} “${debounced}”` : t('Type a word to search the catalog.')}</p></div>{debounced ? page.loading ? <LoadingState label="Searching products…" /> : page.error && page.products.length === 0 ? <ErrorState message={page.error} /> : <><ProductGrid products={page.products} emptyTitle={t('No products found')} emptyDescription={t('Try a shorter search or browse the active categories.')} /><ProductLoadMore loading={page.loadingMore} hasMore={page.hasMore} onLoad={page.loadMore} /></> : <div className="search-suggestions">{categories.map((category) => <Link key={category.id} to={`/categories/${category.slug}`}>{t(category.name)}<ArrowRight size={15} /></Link>)}</div>}</div>
}
